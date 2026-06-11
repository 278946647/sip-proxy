from __future__ import annotations

import json
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .models import Node, SocksProfile
from .monitor import node_is_online
from .socks_parse import format_socks_address
from .timeutil import ensure_utc, utc_now


def _alert_id(alert_type: str, node_id: int | None = None, line_id: int | None = None) -> int:
    key = f"{alert_type}:{node_id}:{line_id}"
    return abs(hash(key)) % 2_000_000_000


async def compute_active_alerts(session: AsyncSession) -> list[dict[str, Any]]:
    """Return alerts for faults that exist right now (not historical log)."""
    now = utc_now()
    out: list[dict[str, Any]] = []

    nodes = (await session.execute(select(Node).order_by(Node.id))).scalars().all()
    for node in nodes:
        if not node.is_active:
            continue
        if not node_is_online(node):
            seen = ensure_utc(node.last_seen_at)
            last = seen.isoformat() if seen else "never"
            out.append(
                {
                    "id": _alert_id("node_offline", node.id),
                    "node_id": node.id,
                    "line_id": None,
                    "level": "critical",
                    "type": "node_offline",
                    "message": f"Node {node.name}(#{node.id}) offline — last heartbeat {last}",
                    "created_at": now,
                }
            )

        metrics: dict[str, Any] = {}
        if node.last_metrics_json:
            try:
                raw = json.loads(node.last_metrics_json)
                if isinstance(raw, dict):
                    metrics = raw
            except json.JSONDecodeError:
                metrics = {}

        if metrics.get("control_plane_reachable") is False:
            out.append(
                {
                    "id": _alert_id("control_plane_unreachable", node.id),
                    "node_id": node.id,
                    "line_id": None,
                    "level": "warn",
                    "type": "control_plane_unreachable",
                    "message": f"Node {node.name} reports control plane unreachable from agent",
                    "created_at": now,
                }
            )

        for svc, info in (metrics.get("services") or {}).items():
            if svc == "nftables" or not isinstance(info, dict):
                continue
            if info.get("active", True):
                continue
            status = info.get("status") or info.get("message") or "not running"
            out.append(
                {
                    "id": _alert_id(f"service_down_{svc}", node.id),
                    "node_id": node.id,
                    "line_id": None,
                    "level": "critical",
                    "type": f"service_down_{svc}",
                    "message": f"Node {node.name}: service {svc} {status}",
                    "created_at": now,
                }
            )

    socks_rows = (await session.execute(select(SocksProfile).order_by(SocksProfile.id))).scalars().all()
    for sp in socks_rows:
        if sp.is_healthy:
            continue
        addr = format_socks_address(sp.host, sp.port, sp.username, sp.password)
        out.append(
            {
                "id": _alert_id(f"socks_down_{sp.id}"),
                "node_id": None,
                "line_id": None,
                "level": "warn",
                "type": f"socks_down_{sp.id}",
                "message": f"SOCKS {sp.name} ({addr}) unhealthy or unreachable",
                "created_at": now,
            }
        )

    out.sort(key=lambda a: (0 if str(a["type"]).startswith("socks_down_") else 1, a["type"]))
    return out
