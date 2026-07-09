from __future__ import annotations

import datetime as dt
import json
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .alerts import notify_alert, send_email
from .models import AlertEvent, Node
from .node_traffic import (
    TRAFFIC_QUOTA_CRITICAL_PERCENT,
    TRAFFIC_QUOTA_WARN_PERCENT,
    build_node_traffic_overview,
    record_node_network_traffic,
)
from .settings import settings
from .timeutil import utc_now


async def _check_traffic_quota_alerts(session: AsyncSession, node: Node) -> None:
    overview = await build_node_traffic_overview(session, node)
    quota_gb = overview.get("monthly_quota_gb")
    pct = overview.get("quota_used_percent")
    if not quota_gb or pct is None:
        return

    pct_int = int(pct)
    if pct_int >= TRAFFIC_QUOTA_CRITICAL_PERCENT:
        level = "critical"
        alert_type = "traffic_quota_critical_95"
        subject = f"[GFC] Traffic quota critical ({pct_int}%): {node.name}"
    elif pct_int >= TRAFFIC_QUOTA_WARN_PERCENT:
        level = "warn"
        alert_type = "traffic_quota_warn_85"
        subject = f"[GFC] Traffic quota warning ({pct_int}%): {node.name}"
    else:
        return

    msg = (
        f"Node {node.name}(#{node.id}) monthly traffic quota at {pct_int}% "
        f"({quota_gb} GB billing period limit)"
    )
    created = await emit_alert(
        session,
        node_id=node.id,
        level=level,
        alert_type=alert_type,
        message=msg,
    )
    if created:
        notify_alert(subject=subject, body=msg)


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

    await record_node_network_traffic(session, node, metrics.get("network_traffic"))
    await _check_traffic_quota_alerts(session, node)

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
