"""Client device API (activation, heartbeat, config pull)."""
from __future__ import annotations

import datetime as dt
import json
import logging
import secrets
from typing import Any

from fastapi import APIRouter, Depends, Header, HTTPException
from sqlalchemy import delete, select
from sqlalchemy.exc import IntegrityError, OperationalError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from .client_config import (
    build_client_disabled_payload,
    build_client_payload,
    client_payload_version,
)
from .line_code import decode_line_code as _decode_line_code
from .db import get_session
from .models import ClientDevice, ClientDeviceTombstone, ClientToken, ConfigBundle, FlowStat, Line
from .schemas import (
    ClientActivateIn,
    ClientActivateResponse,
    ClientConfigAckIn,
    ClientHeartbeatRequest,
    ClientHeartbeatResponse,
    ClientRuntimeUpdateIn,
    ConfigBundleOut,
    DeviceCommandOut,
    ReverseSSHCommandOut,
    ReverseSSHPortsOut,
)
from .reverse_ssh import (
    build_reverse_ssh_command,
    ensure_device_reverse_ports,
    session_active,
    sync_authorized_keys,
    validate_ssh_public_key,
)
from .webssh_keys import webssh_public_key_line
from .security import hash_token, load_token_secrets, new_token
from .settings import settings
from .timeutil import utc_now

router = APIRouter(prefix="/clients", tags=["clients"])
logger = logging.getLogger(__name__)


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


_PLACEHOLDER_DEVICE_NAMES = frozenset(
    {
        "",
        "(none)",
        "none",
        "openwrt",
        "immortalwrt",
        "localhost",
        "gfc-client",
    }
)


def _is_placeholder_device_name(name: str | None) -> bool:
    return (name or "").strip().lower() in _PLACEHOLDER_DEVICE_NAMES


def _initial_device_name(requested: str | None, tid: str) -> str:
    """Prefer a real client name; otherwise use line TID for easy identification."""
    name = (requested or "").strip()
    if _is_placeholder_device_name(name):
        return tid
    return name


def _name_source(device: ClientDevice) -> str:
    return (getattr(device, "name_source", None) or "auto").strip().lower()


async def _active_tombstone(
    session: AsyncSession, device_key: str
) -> ClientDeviceTombstone | None:
    return (
        await session.execute(
            select(ClientDeviceTombstone).where(
                ClientDeviceTombstone.device_key == device_key,
                ClientDeviceTombstone.reclaimed_at.is_(None),
            )
        )
    ).scalars().first()


async def _ensure_reverse_ports(session: AsyncSession, device: ClientDevice) -> None:
    await ensure_device_reverse_ports(session, device)


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
    if not line or not line.is_enabled:
        raise HTTPException(400, "line not found or disabled")
    if line.client_uuid and payload.get("uuid") and line.client_uuid != payload.get("uuid"):
        raise HTTPException(400, "line code uuid mismatch")

    device_key = _device_key_from_mac(body.lan_mac, body.device_id)

    tombstone = await _active_tombstone(session, device_key)
    if tombstone:
        raise HTTPException(
            403,
            "device was hard-retired; ask an admin to reclaim it before activating",
        )

    existing = (
        await session.execute(select(ClientDevice).where(ClientDevice.device_key == device_key))
    ).scalars().first()

    # Platform binding is authoritative: revoked devices must not re-bind via line code.
    if existing and existing.binding_revoked_at is not None and existing.line_id is None:
        raise HTTPException(
            403,
            "line binding revoked; assign a line from the control platform",
        )

    # If already bound on platform, keep platform line — do not let stale code override.
    if existing and existing.line_id and existing.line_id != line.id:
        raise HTTPException(
            409,
            "device already bound to another line; unbind or rebind from the control platform",
        )

    bound = line.client_device
    if bound and (not existing or bound.id != existing.id):
        if existing and existing.line_id and existing.line_id != line.id:
            raise HTTPException(409, "device already bound to another line")
        bound.line_id = None
        bound.binding_revoked_at = utc_now()
        session.add(bound)
        await session.flush()

    if existing:
        device = existing
        # Prefer existing platform binding when set.
        if existing.line_id is None:
            device.line_id = line.id
        device.binding_revoked_at = None
        device.code_cleared_at = None
        if _name_source(device) != "admin":
            device.name = _initial_device_name(body.device_name, line.tid)
            device.name_source = "auto"
        device.lan_mac = body.lan_mac
        device.device_id = body.device_id or device_key
        device.proxy_mode = body.proxy_mode
        device.agent_version = body.agent_version
        device.is_active = True
        await _ensure_reverse_ports(session, device)
    else:
        device = ClientDevice(
            device_key=device_key,
            name=_initial_device_name(body.device_name, line.tid),
            name_source="auto",
            lan_mac=body.lan_mac,
            device_id=body.device_id or device_key,
            line_id=line.id,
            proxy_mode=body.proxy_mode,
            agent_version=body.agent_version,
        )
        session.add(device)
        await session.flush()
        await _ensure_reverse_ports(session, device)

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
        try:
            from .reality_util import default_reality_config

            node.reality_config_json = json.dumps(
                default_reality_config(), ensure_ascii=False
            )
            session.add(node)
        except RuntimeError as exc:
            logger.warning("reality keygen deferred: %s", exc)

    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(409, "device or line binding conflict") from exc
    except OperationalError as exc:
        await session.rollback()
        raise HTTPException(
            503,
            "client database not ready — restart control-plane API to apply migrations",
        ) from exc

    await session.refresh(device)

    return ClientActivateResponse(
        device_id=device.id,
        device_key=device.device_key,
        client_token=raw_token,
        line_id=device.line_id or line.id,
        tid=line.tid,
    )


async def _record_tunnel_flow(
    session: AsyncSession,
    device: ClientDevice,
    metrics: dict[str, Any] | None,
) -> None:
    if not metrics or not device.line_id:
        return
    tunnel = metrics.get("tunnel_traffic")
    if not isinstance(tunnel, dict):
        return
    try:
        bytes_in = int(tunnel.get("bytes_in") or 0)
        bytes_out = int(tunnel.get("bytes_out") or 0)
        window_seconds = int(tunnel.get("window_seconds") or 10)
        active_conns = int(tunnel.get("active_conns") or 0)
    except (TypeError, ValueError):
        return
    if bytes_in < 0 or bytes_out < 0:
        return
    if bytes_in == 0 and bytes_out == 0 and active_conns == 0:
        return

    line = await session.get(Line, device.line_id)
    if not line:
        return

    now = utc_now()
    session.add(
        FlowStat(
            node_id=line.node_id,
            line_id=line.id,
            window_start=now,
            window_seconds=max(1, window_seconds),
            bytes_in=bytes_in,
            bytes_out=bytes_out,
            active_conns=active_conns,
        )
    )
    cutoff = now - dt.timedelta(hours=25)
    await session.execute(delete(FlowStat).where(FlowStat.window_start < cutoff))


@router.post("/heartbeat", response_model=ClientHeartbeatResponse)
async def client_heartbeat(
    body: ClientHeartbeatRequest,
    session: AsyncSession = Depends(get_session),
    authorization: str | None = Header(default=None),
) -> ClientHeartbeatResponse:
    device = await _auth_client(session, authorization)
    device.last_seen_at = utc_now()

    # Name sync: only auto-sourced names accept client reports / TID fill.
    if _name_source(device) != "admin":
        if body.device_name and not _is_placeholder_device_name(body.device_name):
            device.name = body.device_name.strip()
        elif _is_placeholder_device_name(device.name):
            line = device.line
            if line is None and device.line_id:
                line = await session.get(Line, device.line_id)
            if line and line.tid:
                device.name = line.tid

    if body.agent_version:
        device.agent_version = body.agent_version
    if body.proxy_mode:
        device.proxy_mode = body.proxy_mode

    await ensure_device_reverse_ports(session, device)

    key_updated = False
    if body.ssh_public_key:
        try:
            device.ssh_public_key = validate_ssh_public_key(body.ssh_public_key)
            key_updated = True
        except ValueError as exc:
            logger.warning("invalid ssh public key from device %s: %s", device.id, exc)

    if body.reverse_ssh_status and isinstance(body.reverse_ssh_status, dict):
        if body.reverse_ssh_status.get("active"):
            device.reverse_ssh_tunnel_reported_at = utc_now()
        elif session_active(device):
            device.reverse_ssh_tunnel_reported_at = None

    if not session_active(device):
        device.reverse_ssh_tunnel_reported_at = None

    # Acknowledge pending device command (e.g. soft factory reset).
    if body.device_command_ack and isinstance(body.device_command_ack, dict):
        ack_id = str(body.device_command_ack.get("request_id") or body.device_command_ack.get("requestId") or "")
        pending = None
        if device.pending_device_command_json:
            try:
                pending = json.loads(device.pending_device_command_json)
            except json.JSONDecodeError:
                pending = None
        if pending and ack_id and ack_id == str(pending.get("requestId") or pending.get("request_id") or ""):
            device.pending_device_command_json = None
            if pending.get("action") == "factory_reset_soft":
                device.code_cleared_at = utc_now()

    if body.metrics is not None:
        device.last_metrics_json = json.dumps(body.metrics, ensure_ascii=False)
        await _record_tunnel_flow(session, device, body.metrics)
    session.add(device)
    await session.commit()
    if key_updated:
        await sync_authorized_keys(session)

    cmd = build_reverse_ssh_command(device)
    reverse_ssh = None
    if cmd:
        reverse_ssh = ReverseSSHCommandOut(
            enabled=cmd["enabled"],
            host=cmd["host"],
            port=cmd.get("port", settings.reverse_ssh_sshd_port),
            user=cmd["user"],
            expires_at=device.reverse_ssh_session_expires_at,
            ports=ReverseSSHPortsOut(**cmd["ports"]) if cmd.get("ports") else None,
            targets=cmd.get("targets") or [],
        )

    device_command = None
    if device.pending_device_command_json:
        try:
            pending = json.loads(device.pending_device_command_json)
            action = str(pending.get("action") or "")
            req_id = str(pending.get("requestId") or pending.get("request_id") or "")
            if action and req_id:
                device_command = DeviceCommandOut(action=action, request_id=req_id)
        except json.JSONDecodeError:
            pass

    return ClientHeartbeatResponse(
        server_time=utc_now(),
        reverse_ssh=reverse_ssh,
        webssh_authorized_key=webssh_public_key_line(),
        device_command=device_command,
    )


@router.patch("/me/runtime")
async def client_update_runtime(
    body: ClientRuntimeUpdateIn,
    session: AsyncSession = Depends(get_session),
    authorization: str | None = Header(default=None),
) -> dict[str, str | bool]:
    device = await _auth_client(session, authorization)
    data = body.model_dump(exclude_unset=True)
    if "proxy_mode" in data:
        device.proxy_mode = data["proxy_mode"]
    if "routing_scheme" in data:
        device.routing_scheme = data["routing_scheme"]
    session.add(device)
    await session.commit()
    return {
        "ok": True,
        "proxy_mode": device.proxy_mode or "gateway",
        "routing_scheme": device.routing_scheme or "split",
    }


@router.get("/me/config", response_model=ConfigBundleOut)
async def client_config(
    session: AsyncSession = Depends(get_session),
    authorization: str | None = Header(default=None),
) -> ConfigBundleOut:
    device = await _auth_client(session, authorization)

    line: Line | None = None
    if device.line_id:
        stmt = (
            select(Line)
            .where(Line.id == device.line_id)
            .options(selectinload(Line.node), selectinload(Line.socks_profile))
        )
        line = (await session.execute(stmt)).scalars().first()

    if not device.line_id or not line or not line.node or not line.is_enabled:
        reason = "line_unbound"
        if line and not line.is_enabled:
            reason = "line_disabled"
        elif device.line_id and not line:
            reason = "line_deleted"
        payload = build_client_disabled_payload(device, reason)
        version = client_payload_version(payload)
        return ConfigBundleOut(version=version, payload=payload)

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
