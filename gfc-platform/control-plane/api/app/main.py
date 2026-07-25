from __future__ import annotations

import asyncio
import datetime as dt
import json
import logging
from contextlib import asynccontextmanager
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, generate_latest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .admin import router as admin_router
from .artifacts import admin_router as artifacts_admin_router
from .clients import router as clients_router
from .auth_routes import router as auth_router
from .remote_proxy import root_shim_router, router as remote_router
from .webssh import router as webssh_router
from .email_settings import load_smtp_settings
from .platform_secrets import ensure_platform_secrets, get_bootstrap_tokens
from .db import async_session_factory, engine, get_session
from .alerts import send_email
from .migrate import migrate_sqlite
from .models import Base, ConfigBundle, Line, Node, NodeToken, PlatformUser, SocksProfile
from .node_config import build_node_payload, payload_version
from .node_public_ip import normalize_node_public_ip
from .monitor import monitor_loop
from .node_health import emit_alert, process_heartbeat_metrics
from .reverse_ssh import sync_authorized_keys
from .webssh_keys import ensure_webssh_keypair, identity_path, public_key_path
from .schemas import (
    ActivateRequest,
    ActivateResponse,
    ConfigAckIn,
    ConfigBundleOut,
    HeartbeatRequest,
    HeartbeatResponse,
)
from .security import hash_password, hash_token, load_token_secrets, new_token
from .settings import settings

logger = logging.getLogger(__name__)

@asynccontextmanager
async def _lifespan(_app: FastAPI):
    try:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        await migrate_sqlite(engine)
    except Exception:
        logger.exception("database bootstrap failed")
        raise
    async with async_session_factory() as session:
        result = await session.execute(select(PlatformUser).limit(1))
        admin = result.scalar_one_or_none()
        if admin is None:
            session.add(
                PlatformUser(
                    username="admin",
                    role="admin",
                    password_hash=hash_password(settings.admin_default_password),
                )
            )
            await session.commit()
        else:
            if not admin.password_hash:
                admin.password_hash = hash_password(settings.admin_default_password)
                session.add(admin)
                await session.commit()
        await load_smtp_settings(session)
        await ensure_platform_secrets(session)
        try:
            ensure_webssh_keypair()
            if not identity_path().is_file() or not public_key_path().is_file():
                raise RuntimeError("webssh_id missing after ensure_webssh_keypair")
            logger.info("webssh keypair ready at %s", identity_path())
        except Exception:
            logger.exception(
                "webssh keypair bootstrap failed — WebSSH will not work until "
                "/data/pki/webssh_id exists (check openssh-client in API image)"
            )
        try:
            await sync_authorized_keys(session)
        except Exception:
            logger.exception("reverse ssh authorized_keys sync failed (continuing)")

    stop = asyncio.Event()
    task = asyncio.create_task(monitor_loop(stop))
    yield
    stop.set()
    await task


app = FastAPI(title=settings.api_title, version=settings.api_version, lifespan=_lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth_router)
app.include_router(admin_router)
app.include_router(artifacts_admin_router)
app.include_router(clients_router)
app.include_router(remote_router)
app.include_router(root_shim_router)
app.include_router(webssh_router)


@app.get("/health")
async def health() -> dict[str, bool]:
    return {"ok": True}

hb_counter = Counter("gfc_node_heartbeats_total", "Total node heartbeats", ["node_id"])
node_last_seen = Gauge("gfc_node_last_seen_seconds", "Node last seen epoch seconds", ["node_id"])


def _bootstrap_tokens() -> set[str]:
    return get_bootstrap_tokens()


async def _auth_node(
    session: AsyncSession,
    authorization: str | None,
) -> Node:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="missing node token")
    token = authorization.split(" ", 1)[1].strip()
    secrets_cfg = load_token_secrets()
    token_h = hash_token(token, secrets_cfg.salt)
    stmt = (
        select(Node)
        .join(NodeToken, NodeToken.node_id == Node.id)
        .where(NodeToken.token_hash == token_h)
        .where(NodeToken.revoked_at.is_(None))
    )
    node = (await session.execute(stmt)).scalars().first()
    if not node:
        raise HTTPException(status_code=401, detail="invalid node token")
    return node


@app.post("/nodes/activate", response_model=ActivateResponse)
async def activate_node(
    body: ActivateRequest,
    session: AsyncSession = Depends(get_session),
) -> ActivateResponse:
    if body.bootstrap_token not in _bootstrap_tokens():
        raise HTTPException(status_code=403, detail="invalid bootstrap token")

    import secrets as sec

    node_key = sec.token_hex(16)
    node = Node(
        node_key=node_key,
        name=body.node_name,
        region=body.region,
        country=body.region,
        public_ip=normalize_node_public_ip(body.public_ip),
        agent_version=body.agent_version,
        last_seen_at=dt.datetime.now(dt.timezone.utc),
    )
    session.add(node)
    await session.flush()

    raw_token = new_token("node")
    secrets_cfg = load_token_secrets()
    token_h = hash_token(raw_token, secrets_cfg.salt)
    session.add(NodeToken(node_id=node.id, token_hash=token_h))
    await session.commit()

    return ActivateResponse(node_id=node.id, node_key=node.node_key, node_token=raw_token)


@app.post("/nodes/bootstrap-check")
async def bootstrap_check(body: ActivateRequest) -> dict[str, bool]:
    """Validate bootstrap token without registering a node (for install scripts)."""
    if body.bootstrap_token not in _bootstrap_tokens():
        raise HTTPException(status_code=403, detail="invalid bootstrap token")
    return {"ok": True}


@app.post("/nodes/heartbeat", response_model=HeartbeatResponse)
async def heartbeat(
    body: HeartbeatRequest,
    authorization: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
) -> HeartbeatResponse:
    node = await _auth_node(session, authorization)
    node.last_seen_at = dt.datetime.now(dt.timezone.utc)
    public_ip = normalize_node_public_ip(body.public_ip)
    if public_ip:
        node.public_ip = public_ip
    if body.node_name and body.node_name.strip():
        node.name = body.node_name.strip()
    if body.agent_version:
        node.agent_version = body.agent_version
    session.add(node)
    await process_heartbeat_metrics(session, node, body.metrics)
    await session.commit()
    hb_counter.labels(node_id=str(node.id)).inc()
    if node.last_seen_at:
        node_last_seen.labels(node_id=str(node.id)).set(node.last_seen_at.timestamp())
    return HeartbeatResponse(ok=True, server_time=dt.datetime.now(dt.timezone.utc))


@app.get("/nodes/me/config", response_model=ConfigBundleOut)
async def pull_config(
    authorization: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
) -> ConfigBundleOut:
    node = await _auth_node(session, authorization)

    lines = (await session.execute(select(Line).where(Line.node_id == node.id))).scalars().all()
    socks = (await session.execute(select(SocksProfile))).scalars().all()
    socks_by_id = {s.id: s for s in socks}
    payload = build_node_payload(node, lines, socks_by_id)
    reality = payload.get("clientIngress", {}).get("reality") or {}
    reality_json = json.dumps(reality, ensure_ascii=False, separators=(",", ":"))
    hy2 = payload.get("clientIngress", {}).get("hysteria2") or {}
    hy2_json = json.dumps(hy2, ensure_ascii=False, separators=(",", ":"))
    if payload.get("clientIngress", {}).get("enabled"):
        if node.reality_config_json != reality_json:
            node.reality_config_json = reality_json
            session.add(node)
        if getattr(node, "hysteria2_config_json", None) != hy2_json:
            node.hysteria2_config_json = hy2_json
            session.add(node)
    # Persist any newly generated per-line hy2 passwords.
    for line in lines:
        session.add(line)
    version = payload_version(payload)

    cached_ok = node.current_config_version == version
    if cached_ok:
        last = (
            await session.execute(
                select(ConfigBundle)
                .where(ConfigBundle.node_id == node.id)
                .where(ConfigBundle.version == version)
                .order_by(ConfigBundle.id.desc())
                .limit(1)
            )
        ).scalars().first()
        if last:
            cached = json.loads(last.payload_json)
            # Rebuild if bundle predates schema upgrades.
            if node.static_routes_json and not cached.get("staticRoutes"):
                cached_ok = False
            if node.connect_mode == "openvpn" and node.vpn_config_json and not cached.get("vpn"):
                cached_ok = False
            if cached.get("connectMode") != payload.get("connectMode"):
                cached_ok = False
            if cached_ok:
                return ConfigBundleOut(version=version, payload=cached)

    payload_json = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    session.add(ConfigBundle(node_id=node.id, version=version, payload_json=payload_json))
    node.current_config_version = version
    session.add(node)
    await session.commit()

    return ConfigBundleOut(version=version, payload=payload)


@app.post("/nodes/me/config/ack")
async def ack_config(
    body: ConfigAckIn,
    authorization: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
) -> dict[str, Any]:
    node = await _auth_node(session, authorization)
    if body.status == "failed":
        msg = body.message or f"config {body.version} apply failed"
        send_email(
            subject=f"[GFC] Config apply failed on node {node.name}({node.id})",
            body=msg,
        )
        await emit_alert(
            session,
            node_id=node.id,
            level="critical",
            alert_type="config_apply_failed",
            message=msg,
        )
    await session.commit()
    return {"ok": True}


@app.get("/healthz")
async def healthz() -> dict[str, Any]:
    webssh_ok = identity_path().is_file() and public_key_path().is_file()
    return {"ok": True, "webssh_keypair": webssh_ok}


@app.get("/metrics")
async def metrics() -> Any:
    from fastapi.responses import Response

    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
