"""Reverse SSH session management, port allocation, and bastion key rendering."""
from __future__ import annotations

import json
import logging
import os
import socket
from pathlib import Path
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from .models import ClientDevice
from .settings import settings
from .timeutil import ensure_utc, utc_now

logger = logging.getLogger(__name__)


def ports_per_device() -> int:
    return max(1, settings.client_ports_per_device)


def ssh_port_min() -> int:
    return settings.client_ssh_port_base


def ssh_port_max() -> int:
    return settings.client_ssh_port_max - (ports_per_device() - 1)


def bastion_host() -> str:
    host = (settings.public_ip or "").strip()
    if host:
        return host
    url = (settings.public_url or "").strip()
    if "://" in url:
        url = url.split("://", 1)[1]
    return url.split(":")[0].split("/")[0] or "127.0.0.1"


def validate_ssh_public_key(key: str) -> str:
    key = " ".join(key.strip().split())
    if not key:
        raise ValueError("empty ssh public key")
    parts = key.split()
    if len(parts) < 2:
        raise ValueError("invalid ssh public key format")
    if parts[0] not in {"ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256"}:
        raise ValueError("unsupported ssh key type")
    return key


async def allocate_reverse_ports(session: AsyncSession) -> tuple[int, int]:
    """Allocate sequential (ssh_port, http_port) from the pool."""
    step = ports_per_device()
    lo = ssh_port_min()
    hi = ssh_port_max()
    if hi < lo:
        raise RuntimeError("invalid reverse ssh port pool")

    stmt = select(func.max(ClientDevice.reverse_ssh_port))
    current = (await session.execute(stmt)).scalar_one_or_none()
    next_port = lo if current is None else int(current) + step
    if next_port > hi:
        raise RuntimeError(f"reverse ssh port pool exhausted ({lo}-{settings.client_ssh_port_max})")

    used = set(
        (await session.execute(select(ClientDevice.reverse_ssh_port))).scalars().all()
    ) | set(
        (await session.execute(select(ClientDevice.reverse_http_port))).scalars().all()
    )
    while next_port <= hi:
        pair = [next_port + i for i in range(step)]
        if all(p not in used for p in pair):
            return pair[0], pair[1] if step > 1 else pair[0] + 1
        next_port += step
    raise RuntimeError(f"reverse ssh port pool exhausted ({lo}-{settings.client_ssh_port_max})")


async def ensure_device_reverse_ports(session: AsyncSession, device: ClientDevice) -> None:
    """Allocate reverse SSH/HTTP ports for legacy devices missing the port pair."""
    if device.reverse_ssh_port and device.reverse_http_port:
        return
    ssh_port, http_port = await allocate_reverse_ports(session)
    device.reverse_ssh_port = ssh_port
    device.reverse_http_port = http_port


def session_active(device: ClientDevice) -> bool:
    exp = ensure_utc(device.reverse_ssh_session_expires_at)
    if exp is None:
        return False
    # SQLite may return naive UTC; never compare aware vs naive (TypeError → 500 on list).
    return utc_now() < exp


def session_state(device: ClientDevice) -> str:
    if not session_active(device):
        return "idle"
    if device.reverse_ssh_tunnel_reported_at:
        return "ready"
    return "connecting"


def parse_session_targets(device: ClientDevice) -> list[str]:
    raw = (device.reverse_ssh_session_targets or "").strip()
    if not raw:
        return []
    try:
        data = json.loads(raw)
        if isinstance(data, list):
            return [str(x) for x in data]
    except json.JSONDecodeError:
        pass
    return [t.strip() for t in raw.split(",") if t.strip()]


def build_reverse_ssh_command(device: ClientDevice) -> dict[str, Any] | None:
    if not session_active(device):
        return None
    if not device.reverse_ssh_port or not device.ssh_public_key:
        return None
    targets = parse_session_targets(device) or ["ssh"]
    ports: dict[str, int] = {}
    if device.reverse_ssh_port:
        ports["ssh"] = device.reverse_ssh_port
    if device.reverse_http_port:
        ports["http"] = device.reverse_http_port
    if not ports:
        return None
    return {
        "enabled": True,
        "host": bastion_host(),
        "port": settings.reverse_ssh_sshd_port,
        "user": settings.reverse_ssh_user,
        "expires_at": device.reverse_ssh_session_expires_at.isoformat()
        if device.reverse_ssh_session_expires_at
        else None,
        "ports": ports,
        "targets": targets,
    }


def probe_local_port(port: int, timeout: float = 0.8) -> bool:
    if port <= 0:
        return False
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout):
            return True
    except OSError:
        return False


def tunnel_ready(device: ClientDevice) -> bool:
    if not session_active(device):
        return False
    targets = parse_session_targets(device) or ["ssh"]
    if "ssh" in targets and device.reverse_ssh_port:
        if not probe_local_port(device.reverse_ssh_port):
            return False
    if any(t in targets for t in ("web", "flash")) and device.reverse_http_port:
        if not probe_local_port(device.reverse_http_port):
            return False
    return True


def render_authorized_keys(devices: list[ClientDevice]) -> str:
    lines: list[str] = []
    for dev in devices:
        if not dev.ssh_public_key:
            continue
        key = dev.ssh_public_key.strip()
        comment = f"device_id={dev.id}"
        lines.append(
            f'restrict,port-forwarding,permitlisten="127.0.0.1:*" {key} {comment}'
        )
    return "\n".join(lines) + ("\n" if lines else "")


async def sync_authorized_keys(session: AsyncSession) -> None:
    path = (settings.reverse_ssh_authorized_keys_path or "").strip()
    if not path:
        return
    stmt = select(ClientDevice).where(ClientDevice.ssh_public_key.is_not(None))
    devices = (await session.execute(stmt)).scalars().all()
    content = render_authorized_keys(list(devices))
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(target.suffix + ".tmp")
    tmp.write_text(content, encoding="utf-8")
    os.replace(tmp, target)
    logger.info("updated reverse ssh authorized_keys (%d devices)", len(devices))
