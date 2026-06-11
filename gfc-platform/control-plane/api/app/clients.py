"""Client device API (activation, heartbeat, config pull)."""
from __future__ import annotations

import datetime as dt
import json
import secrets

from fastapi import APIRouter, Depends, Header, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from .client_config import build_client_payload, client_payload_version
from .line_code import decode_line_code as _decode_line_code
from .db import get_session
from .models import ClientDevice, ClientToken, ConfigBundle, Line
from .schemas import (
    ClientActivateIn,
    ClientActivateResponse,
    ClientConfigAckIn,
    ClientHeartbeatRequest,
    ClientHeartbeatResponse,
    ConfigBundleOut,
)
from .security import hash_token, load_token_secrets, new_token
from .settings import settings
from .timeutil import utc_now

router = APIRouter(prefix="/clients", tags=["clients"])


async def _auth_client(
    session: AsyncSession,
    authorization: str | None,
) -> ClientDevice:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="missing client token")
    token = authorization.split(" ", 1)[1].strip()
    secrets_cfg = load_token_secrets()
    token_h = hash_token(token, secrets_cfg.salt)
    stmt = (
        select(ClientDevice)
        .join(ClientToken, ClientToken.device_id == ClientDevice.id)
        .where(
            ClientToken.token_hash == token_h,
            ClientToken.revoked_at.is_(None),
            ClientDevice.is_active.is_(True),
        )
        .options(selectinload(ClientDevice.line).selectinload(Line.node))
    )
    device = (await session.execute(stmt)).scalars().first()
    if not device:
        raise HTTPException(status_code=401, detail="invalid client token")
    return device


def _device_key_from_mac(lan_mac: str | None, device_id: str | None) -> str:
    if device_id:
        return device_id.strip().upper()
    if lan_mac:
        return lan_mac.replace(":", "").replace("-", "").upper()
    return secrets.token_hex(8).upper()


@router.post("/activate", response_model=ClientActivateResponse)
async def activate_client(
    body: ClientActivateIn,
    session: AsyncSession = Depends(get_session),
) -> ClientActivateResponse:
    try:
        payload = _decode_line_code(body.line_code_b32)
    except (ValueError, json.JSONDecodeError) as exc:
        raise HTTPException(400, f"invalid line code: {exc}") from exc

    line_id = payload.get("lineId")
    if not line_id:
        raise HTTPException(400, "line code missing lineId")

    stmt = (
        select(Line)
        .where(Line.id == int(line_id))
        .options(selectinload(Line.node), selectinload(Line.client_device))
    )
    line = (await session.execute(stmt)).scalars().first()
    if not line or not line.is_enabled or line.status != "active":
        raise HTTPException(400, "line not found or inactive")
    if line.client_uuid and payload.get("uuid") and line.client_uuid != payload.get("uuid"):
        raise HTTPException(400, "line code uuid mismatch")

    device_key = _device_key_from_mac(body.lan_mac, body.device_id)
    existing = (
        await session.execute(select(ClientDevice).where(ClientDevice.device_key == device_key))
    ).scalars().first()

    if existing:
        device = existing
        if existing.line_id and existing.line_id != line.id:
            raise HTTPException(409, "device already bound to another line")
        device.line_id = line.id
        device.name = body.device_name
        device.lan_mac = body.lan_mac
        device.device_id = body.device_id or device_key
        device.proxy_mode = body.proxy_mode
        device.agent_version = body.agent_version
    else:
        device = ClientDevice(
            device_key=device_key,
            name=body.device_name,
            lan_mac=body.lan_mac,
            device_id=body.device_id or device_key,
            line_id=line.id,
            proxy_mode=body.proxy_mode,
            agent_version=body.agent_version,
            reverse_ssh_port=settings.client_ssh_port_base
            + (int(device_key[:4], 16) % 1000 if len(device_key) >= 4 else secrets.randbelow(1000)),
        )
        session.add(device)
        await session.flush()

    raw_token = new_token("client")
    secrets_cfg = load_token_secrets()
    session.add(
        ClientToken(
            device_id=device.id,
            token_hash=hash_token(raw_token, secrets_cfg.salt),
            expires_at=utc_now() + dt.timedelta(days=365),
        )
    )
    node = line.node
    if node and not node.reality_config_json:
        from .reality_util import default_reality_config

        node.reality_config_json = json.dumps(default_reality_config(), ensure_ascii=False)
        session.add(node)

    await session.commit()
    await session.refresh(device)

    return ClientActivateResponse(
        device_id=device.id,
        device_key=device.device_key,
        client_token=raw_token,
        line_id=line.id,
        tid=line.tid,
    )


@router.post("/heartbeat", response_model=ClientHeartbeatResponse)
async def client_heartbeat(
    body: ClientHeartbeatRequest,
    session: AsyncSession = Depends(get_session),
    authorization: str | None = Header(default=None),
) -> ClientHeartbeatResponse:
    device = await _auth_client(session, authorization)
    device.last_seen_at = utc_now()
    if body.device_name:
        device.name = body.device_name
    if body.agent_version:
        device.agent_version = body.agent_version
    if body.reverse_ssh_port is not None:
        device.reverse_ssh_port = body.reverse_ssh_port
    if body.proxy_mode:
        device.proxy_mode = body.proxy_mode
    if body.metrics is not None:
        device.last_metrics_json = json.dumps(body.metrics, ensure_ascii=False)
    session.add(device)
    await session.commit()
    return ClientHeartbeatResponse(server_time=utc_now())


@router.get("/me/config", response_model=ConfigBundleOut)
async def client_config(
    session: AsyncSession = Depends(get_session),
    authorization: str | None = Header(default=None),
) -> ConfigBundleOut:
    device = await _auth_client(session, authorization)
    if not device.line_id:
        raise HTTPException(400, "device not bound to a line")

    stmt = (
        select(Line)
        .where(Line.id == device.line_id)
        .options(selectinload(Line.node), selectinload(Line.socks_profile))
    )
    line = (await session.execute(stmt)).scalars().first()
    if not line or not line.node:
        raise HTTPException(400, "line or node missing")

    payload = build_client_payload(device, line, line.node, line.socks_profile)
    version = client_payload_version(payload)

    bundle = (
        await session.execute(
            select(ConfigBundle)
            .where(ConfigBundle.node_id == line.node_id, ConfigBundle.version == version)
            .limit(1)
        )
    ).scalars().first()
    if not bundle:
        session.add(
            ConfigBundle(
                node_id=line.node_id,
                version=version,
                payload_json=json.dumps(payload, ensure_ascii=False),
            )
        )
        await session.commit()

    return ConfigBundleOut(version=version, payload=payload)


@router.post("/me/config/ack")
async def client_config_ack(
    body: ClientConfigAckIn,
    session: AsyncSession = Depends(get_session),
    authorization: str | None = Header(default=None),
) -> dict[str, bool]:
    await _auth_client(session, authorization)
    return {"ok": True}
