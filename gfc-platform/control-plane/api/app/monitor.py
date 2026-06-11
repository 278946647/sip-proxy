from __future__ import annotations

import asyncio
import logging

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .alerts import send_email
from .db import async_session_factory
from .models import Node, SocksProfile
from .node_health import emit_alert
from .settings import settings
from .socks_probe import probe_socks, socks_profile_fields
from .timeutil import ensure_utc, seconds_ago

logger = logging.getLogger(__name__)


def node_is_online(node: Node) -> bool:
    ago = seconds_ago(node.last_seen_at)
    return ago is not None and ago < settings.node_offline_threshold_seconds


async def check_nodes_offline(
    session: AsyncSession,
    online_state: dict[int, bool],
) -> None:
    nodes = (await session.execute(select(Node))).scalars().all()
    for node in nodes:
        online = node_is_online(node)
        prev = online_state.get(node.id)
        online_state[node.id] = online

        if prev is None:
            continue
        if prev and not online:
            seen = ensure_utc(node.last_seen_at)
            last = seen.isoformat() if seen else "never"
            msg = f"Node {node.name}(#{node.id}) offline — last heartbeat {last}"
            created = await emit_alert(
                session,
                node_id=node.id,
                level="critical",
                alert_type="node_offline",
                message=msg,
            )
            if created:
                send_email(
                    subject=f"[GFC] Node offline: {node.name}",
                    body=msg,
                )


async def probe_all_socks(session: AsyncSession) -> None:
    rows = (await session.execute(select(SocksProfile))).scalars().all()
    for sp in rows:
        ok, detail = await asyncio.to_thread(
            probe_socks,
            sp.host,
            sp.port,
            sp.username,
            sp.password,
            probe_url=settings.socks_probe_url,
            timeout_seconds=settings.socks_probe_timeout_seconds,
        )
        prev = sp.is_healthy
        sp.is_healthy = ok
        session.add(sp)
        if prev and not ok:
            addr = socks_profile_fields(sp)["address"]
            msg = f"SOCKS {sp.name} ({addr}) unreachable: {detail}"
            await emit_alert(
                session,
                level="warn",
                alert_type=f"socks_down_{sp.id}",
                message=msg,
            )
            send_email(
                subject=f"[GFC] SOCKS offline: {sp.name}",
                body=msg,
            )


async def monitor_loop(stop: asyncio.Event) -> None:
    online_state: dict[int, bool] = {}
    interval = max(15, settings.monitor_interval_seconds)
    logger.info("monitor loop started (interval=%ss)", interval)
    while not stop.is_set():
        try:
            async with async_session_factory() as session:
                await check_nodes_offline(session, online_state)
                await probe_all_socks(session)
                await session.commit()
        except Exception:
            logger.exception("monitor tick failed")
        try:
            await asyncio.wait_for(stop.wait(), timeout=interval)
        except asyncio.TimeoutError:
            pass
