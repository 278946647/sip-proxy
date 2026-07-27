"""P1/P2 live catalog verification (run on control plane host)."""
from __future__ import annotations

import asyncio
import sys
from pathlib import Path

API_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(API_ROOT))

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import async_session_factory, engine
from app.live_catalog import (
    build_client_live_ip,
    build_node_live_catalog,
    compute_catalog_epoch,
    fetch_active_endpoints,
    parse_line_platforms,
    sync_live_catalog_seed,
    validate_resolve_report,
)
from app.migrate import migrate_sqlite
from app.models import Base, Line, LiveEndpoint, LivePlatform, SocksProfile


async def _run() -> int:
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    await migrate_sqlite(engine)

    errors: list[str] = []
    async with async_session_factory() as session:
        await sync_live_catalog_seed(session)

        platforms = (await session.execute(select(LivePlatform))).scalars().all()
        if len(platforms) < 10:
            errors.append(f"expected >=10 platforms, got {len(platforms)}")

        twitch = await session.get(LivePlatform, "twitch")
        if not twitch:
            errors.append("missing twitch platform seed")

        active_yt = (
            await session.execute(
                select(LiveEndpoint)
                .where(LiveEndpoint.platform_id == "youtube_live")
                .where(LiveEndpoint.status == "active")
            )
        ).scalars().all()
        if len(active_yt) < 3:
            errors.append(f"youtube active endpoints want >=3, got {len(active_yt)}")

        line = Line(
            id=999,
            tid="T-verify",
            name="verify",
            source_cidrs="",
            node_id=1,
            live_mode="live_catalog",
            live_platforms_json='["youtube_live","twitch"]',
            is_enabled=True,
            line_type="client",
        )
        line.id = 999
        platforms_ids = parse_line_platforms(line)
        if platforms_ids != ["youtube_live", "twitch"]:
            errors.append(f"parse_line_platforms={platforms_ids}")

        eps = await fetch_active_endpoints(session, platforms_ids)
        if not eps:
            errors.append("no active endpoints for youtube+twitch")

        epoch = compute_catalog_epoch(platforms_ids, eps)
        if not epoch:
            errors.append("empty catalog epoch")

        catalog = await build_node_live_catalog(session, [line], {})
        if not catalog.get("tasks"):
            errors.append("node liveCatalog tasks empty for live_catalog line")

        task = catalog["tasks"][0]
        ok, alert_type, _ = validate_resolve_report(
            1,
            task,
            {
                "lineId": task["lineId"],
                "detourTag": task["detourTag"],
                "egressHint": task.get("egressHint"),
                "cidrs": ["1.2.3.4/32"],
            },
        )
        if not ok:
            errors.append(f"validate_resolve_report failed: {alert_type}")

        bad_ok, bad_type, _ = validate_resolve_report(
            1,
            task,
            {"lineId": task["lineId"], "detourTag": "client-0", "cidrs": []},
        )
        if bad_ok or bad_type != "resolve_vantage_mismatch":
            errors.append("expected V1 mismatch detection")

        live_ip = await build_client_live_ip(session, 999, line)
        if live_ip is None:
            errors.append("build_client_live_ip returned None (ok if no resolve row)")

    if errors:
        print("FAIL")
        for e in errors:
            print(f"  - {e}")
        return 1
    print("OK: live catalog P1/P2 seed + bundle helpers verified")
    return 0


def main() -> None:
    raise SystemExit(asyncio.run(_run()))


if __name__ == "__main__":
    main()
