"""Forward-node traffic sampling and billing-period accounting."""
from __future__ import annotations

import datetime as dt
from typing import Any

from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from .models import Node, NodeTrafficSample
from .monitor import node_is_online
from .timeutil import ensure_utc, utc_now

SAMPLE_INTERVAL_SECONDS = 300  # 5 minutes — matches UI collection cadence
RECENT_INCREMENT_MINUTES = 7
HOURS_24 = 24
RETENTION_HOURS = 24 * 45


def _default_billing_start() -> dt.datetime:
    now = utc_now()
    return now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)


def ensure_billing_defaults(node: Node) -> None:
    if node.traffic_billing_start_at is None:
        node.traffic_billing_start_at = _default_billing_start()
    if not node.traffic_billing_cycle_days:
        node.traffic_billing_cycle_days = 30
    if node.traffic_correction_bytes is None:
        node.traffic_correction_bytes = 0
    if node.traffic_pending_bytes_in is None:
        node.traffic_pending_bytes_in = 0
    if node.traffic_pending_bytes_out is None:
        node.traffic_pending_bytes_out = 0


def billing_period_end(node: Node) -> dt.datetime:
    ensure_billing_defaults(node)
    start = ensure_utc(node.traffic_billing_start_at) or utc_now()
    days = max(1, int(node.traffic_billing_cycle_days or 30))
    return start + dt.timedelta(days=days)


async def maybe_rollover_billing_period(session: AsyncSession, node: Node) -> bool:
    ensure_billing_defaults(node)
    start = ensure_utc(node.traffic_billing_start_at)
    if start is None:
        node.traffic_billing_start_at = utc_now()
        return False
    if utc_now() < billing_period_end(node):
        return False
    node.traffic_billing_start_at = utc_now()
    node.traffic_correction_bytes = 0
    node.traffic_pending_bytes_in = 0
    node.traffic_pending_bytes_out = 0
    session.add(node)
    return True


async def record_node_network_traffic(
    session: AsyncSession,
    node: Node,
    network: dict[str, Any] | None,
) -> None:
    if not isinstance(network, dict):
        return
    try:
        delta_in = max(0, int(network.get("bytes_in") or 0))
        delta_out = max(0, int(network.get("bytes_out") or 0))
    except (TypeError, ValueError):
        return
    if delta_in == 0 and delta_out == 0:
        return

    ensure_billing_defaults(node)
    await maybe_rollover_billing_period(session, node)

    node.traffic_pending_bytes_in = int(node.traffic_pending_bytes_in or 0) + delta_in
    node.traffic_pending_bytes_out = int(node.traffic_pending_bytes_out or 0) + delta_out
    iface = str(network.get("iface") or "").strip() or None
    if iface:
        node.traffic_monitor_iface = iface

    last_at = ensure_utc(node.traffic_last_sample_at)
    now = utc_now()
    should_flush = last_at is None or (now - last_at).total_seconds() >= SAMPLE_INTERVAL_SECONDS
    if not should_flush:
        session.add(node)
        return

    window_seconds = SAMPLE_INTERVAL_SECONDS
    if last_at is not None:
        window_seconds = max(SAMPLE_INTERVAL_SECONDS, int((now - last_at).total_seconds()))

    session.add(
        NodeTrafficSample(
            node_id=node.id,
            sampled_at=now,
            window_seconds=window_seconds,
            bytes_in=int(node.traffic_pending_bytes_in or 0),
            bytes_out=int(node.traffic_pending_bytes_out or 0),
            iface=node.traffic_monitor_iface,
        )
    )
    node.traffic_last_sample_at = now
    node.traffic_pending_bytes_in = 0
    node.traffic_pending_bytes_out = 0
    session.add(node)

    cutoff = now - dt.timedelta(hours=RETENTION_HOURS)
    await session.execute(delete(NodeTrafficSample).where(NodeTrafficSample.sampled_at < cutoff))


async def _sum_bytes(
    session: AsyncSession,
    node_id: int,
    since: dt.datetime | None = None,
) -> int:
    stmt = select(
        func.coalesce(func.sum(NodeTrafficSample.bytes_in + NodeTrafficSample.bytes_out), 0)
    ).where(NodeTrafficSample.node_id == node_id)
    if since is not None:
        stmt = stmt.where(NodeTrafficSample.sampled_at >= since)
    total = (await session.execute(stmt)).scalar_one()
    return int(total or 0)


async def build_node_traffic_overview(session: AsyncSession, node: Node) -> dict[str, Any]:
    ensure_billing_defaults(node)
    await maybe_rollover_billing_period(session, node)

    now = utc_now()
    since_24h = now - dt.timedelta(hours=HOURS_24)
    since_recent = now - dt.timedelta(minutes=RECENT_INCREMENT_MINUTES)
    billing_start = ensure_utc(node.traffic_billing_start_at)

    last_24h = await _sum_bytes(session, node.id, since_24h)
    recent = await _sum_bytes(session, node.id, since_recent)
    period_raw = await _sum_bytes(session, node.id, billing_start)
    correction = int(node.traffic_correction_bytes or 0)
    billing_period_bytes = period_raw + correction

    quota_gb = node.traffic_monthly_quota_gb
    quota_used_percent = None
    if quota_gb and quota_gb > 0:
        quota_bytes = quota_gb * (1024**3)
        quota_used_percent = round(min(100.0, billing_period_bytes / quota_bytes * 100), 1)

    online = node_is_online(node)
    has_samples = node.traffic_last_sample_at is not None
    if not online:
        status = "offline"
    elif not has_samples:
        status = "no_data"
    else:
        status = "active"

    return {
        "node_id": node.id,
        "node_name": node.name,
        "country": node.country,
        "public_ip": node.public_ip,
        "online": online,
        "last_24h_bytes": last_24h,
        "recent_increment_bytes": recent,
        "billing_period_bytes": billing_period_bytes,
        "billing_cycle_start_at": billing_start,
        "billing_cycle_end_at": billing_period_end(node),
        "billing_cycle_days": int(node.traffic_billing_cycle_days or 30),
        "monthly_quota_gb": quota_gb,
        "quota_used_percent": quota_used_percent,
        "correction_bytes": correction,
        "monitor_iface": node.traffic_monitor_iface,
        "status": status,
        "last_sample_at": node.traffic_last_sample_at,
    }
