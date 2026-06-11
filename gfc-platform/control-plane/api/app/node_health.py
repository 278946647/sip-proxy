from __future__ import annotations

import datetime as dt
import json
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .alerts import send_email
from .models import AlertEvent, Node
from .settings import settings
from .timeutil import utc_now


async def emit_alert(
    session: AsyncSession,
    *,
    node_id: int | None = None,
    line_id: int | None = None,
    level: str,
    alert_type: str,
    message: str,
) -> bool:
    """Insert alert if no duplicate of same type within dedup window. Returns True if created."""
    cutoff = utc_now() - dt.timedelta(minutes=settings.alert_dedup_minutes)
    stmt = (
        select(AlertEvent.id)
        .where(AlertEvent.type == alert_type)
        .where(AlertEvent.created_at >= cutoff)
        .limit(1)
    )
    if node_id is not None:
        stmt = stmt.where(AlertEvent.node_id == node_id)
    if line_id is not None:
        stmt = stmt.where(AlertEvent.line_id == line_id)
    existing = (await session.execute(stmt)).scalar_one_or_none()
    if existing is not None:
        return False

    session.add(
        AlertEvent(
            node_id=node_id,
            line_id=line_id,
            level=level,
            type=alert_type,
            message=message[:512],
        )
    )
    return True


async def process_heartbeat_metrics(
    session: AsyncSession,
    node: Node,
    metrics: dict[str, Any] | None,
) -> None:
    if not metrics:
        return

    node.last_metrics_json = json.dumps(metrics, ensure_ascii=False)
    session.add(node)

    services = metrics.get("services") or {}
    for svc, info in services.items():
        if svc == "nftables":
            continue
        if not isinstance(info, dict):
            continue
        active = info.get("active", True)
        if active:
            continue
        status = info.get("status") or info.get("message") or "not running"
        msg = f"Node {node.name}: service {svc} {status}"
        alert_type = f"service_down_{svc}"
        created = await emit_alert(
            session,
            node_id=node.id,
            level="critical",
            alert_type=alert_type,
            message=msg,
        )
        if created:
            send_email(subject=f"[GFC] Service down on {node.name}: {svc}", body=msg)

    if metrics.get("control_plane_reachable") is False:
        await emit_alert(
            session,
            node_id=node.id,
            level="warn",
            alert_type="control_plane_unreachable",
            message=f"Node {node.name} reports control plane unreachable from agent",
        )
