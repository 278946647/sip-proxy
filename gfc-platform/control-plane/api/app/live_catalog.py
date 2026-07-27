"""Live catalog (mode A) — platform endpoints, per-line resolve, bundle helpers."""
from __future__ import annotations

import datetime as dt
import hashlib
import ipaddress
import json
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .hy2_util import LIVE_MODE_CATALOG, normalize_live_mode
from .models import (
    Line,
    LiveCaptureCandidate,
    LiveEndpoint,
    LivePlatform,
    LiveResolveResult,
    SocksProfile,
)

DOH_URL = "https://1.1.1.1/dns-query"

# (id, display_name, markets, live_strength, is_enabled)
PLATFORM_SPECS: list[tuple[str, str, list[str], str, bool]] = [
    ("youtube_live", "YouTube Live / Shopping", ["global"], "strong", True),
    ("twitch", "Twitch", ["global"], "strong", True),
    ("tiktok_shop", "TikTok Shop / LIVE", ["sea", "us"], "medium", True),
    ("shopee_live", "Shopee Live", ["sea"], "medium", True),
    ("lazada_live", "Lazada Live", ["sea"], "medium", True),
    ("facebook_live", "Facebook Live Shopping", ["global"], "medium", True),
    ("instagram_live", "Instagram Live / Shopping", ["global"], "medium", True),
    ("amazon_ivs", "Amazon IVS", ["global"], "medium", True),
    ("amazon_live", "Amazon Live", ["us", "eu"], "medium", True),
    ("shopify_live", "Shopify Live", ["global"], "medium", True),
    ("whatnot", "Whatnot", ["us"], "low", True),
    ("kwai_shop", "Kwai / Kwai Shop", ["sea"], "low", True),
    ("temu", "Temu", ["global"], "low", False),
    ("aliexpress", "AliExpress", ["global"], "low", True),
    ("ebay_live", "eBay Live", ["us"], "low", True),
    ("walmart_live", "Walmart Live", ["us"], "low", True),
]

# (platform_id, role, match_type, value, confidence, source, status, region|None)
ENDPOINT_SEEDS: list[tuple[str, str, str, str, str, str, str, str | None]] = [
    ("youtube_live", "ingest", "fqdn", "a.rtmp.youtube.com", "high", "official_doc", "active", None),
    ("youtube_live", "ingest", "fqdn", "b.rtmp.youtube.com", "high", "official_doc", "active", None),
    ("youtube_live", "ingest", "fqdn", "c.rtmp.youtube.com", "high", "official_doc", "active", None),
    ("twitch", "ingest", "fqdn", "live.twitch.tv", "high", "official_api", "active", None),
    (
        "twitch",
        "ingest",
        "domain_suffix",
        ".global-contribute.live-video.net",
        "high",
        "official_api",
        "active",
        None,
    ),
    ("tiktok_shop", "ingest", "domain_suffix", ".tiktokcdn.com", "medium", "geosite_seed", "draft", "sea"),
    ("shopee_live", "ingest", "domain_suffix", ".shopee.io", "medium", "geosite_seed", "draft", "sea"),
    ("lazada_live", "ingest", "domain_suffix", ".lazada.sg", "medium", "geosite_seed", "draft", "sg"),
    ("lazada_live", "ingest", "domain_suffix", ".lazada.co.th", "medium", "geosite_seed", "draft", "th"),
    ("facebook_live", "ingest", "domain_suffix", ".fbcdn.net", "low", "geosite_seed", "draft", None),
    ("instagram_live", "ingest", "domain_suffix", ".cdninstagram.com", "low", "geosite_seed", "draft", None),
    ("amazon_ivs", "ingest", "domain_suffix", ".live-video.net", "medium", "official_doc", "draft", None),
    ("amazon_live", "ingest", "domain_suffix", ".amazonlive.com", "medium", "geosite_seed", "draft", None),
    ("shopify_live", "ingest", "domain_suffix", ".shopifycdn.com", "low", "geosite_seed", "draft", None),
    ("whatnot", "ingest", "domain_suffix", ".whatnot.com", "low", "geosite_seed", "draft", None),
    ("kwai_shop", "ingest", "domain_suffix", ".kwai-pro.com", "low", "geosite_seed", "draft", None),
    ("aliexpress", "ingest", "domain_suffix", ".alicdn.com", "low", "geosite_seed", "draft", None),
    ("ebay_live", "ingest", "domain_suffix", ".ebaystatic.com", "low", "geosite_seed", "draft", None),
    ("walmart_live", "ingest", "domain_suffix", ".walmartimages.com", "low", "geosite_seed", "draft", None),
]


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def parse_line_platforms(line: Line) -> list[str]:
    raw = getattr(line, "live_platforms_json", None) or "[]"
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return []
    if not isinstance(data, list):
        return []
    out: list[str] = []
    seen: set[str] = set()
    for item in data:
        slug = str(item).strip()
        if slug and slug not in seen:
            seen.add(slug)
            out.append(slug)
    return out


def serialize_line_platforms(platform_ids: list[str] | None) -> str:
    if not platform_ids:
        return "[]"
    cleaned = []
    seen: set[str] = set()
    for item in platform_ids:
        slug = str(item).strip()
        if slug and slug not in seen:
            seen.add(slug)
            cleaned.append(slug)
    return json.dumps(cleaned, ensure_ascii=False)


async def sync_live_catalog_seed(session: AsyncSession) -> None:
    """Idempotent P2 seed: upsert platforms and missing endpoint rows."""
    now = utc_now()
    for pid, display_name, markets, strength, enabled in PLATFORM_SPECS:
        row = await session.get(LivePlatform, pid)
        if row is None:
            session.add(
                LivePlatform(
                    id=pid,
                    display_name=display_name,
                    markets_json=json.dumps(markets, ensure_ascii=False),
                    live_strength=strength,
                    is_enabled=enabled,
                    created_at=now,
                )
            )
    await session.flush()

    for (
        platform_id,
        role,
        match_type,
        value,
        confidence,
        source,
        status,
        region,
    ) in ENDPOINT_SEEDS:
        existing = (
            await session.execute(
                select(LiveEndpoint)
                .where(LiveEndpoint.platform_id == platform_id)
                .where(LiveEndpoint.match_type == match_type)
                .where(LiveEndpoint.value == value)
            )
        ).scalars().first()
        if existing:
            continue
        session.add(
            LiveEndpoint(
                platform_id=platform_id,
                role=role,
                match_type=match_type,
                value=value,
                confidence=confidence,
                source=source,
                status=status,
                region=region,
                last_verified_at=now if status == "active" else None,
                created_at=now,
            )
        )
    await session.commit()


async def ensure_live_catalog_seed(session: AsyncSession) -> None:
    """Backward-compatible alias for startup hook."""
    await sync_live_catalog_seed(session)


async def list_live_platforms(session: AsyncSession) -> list[dict[str, Any]]:
    rows = (await session.execute(select(LivePlatform).order_by(LivePlatform.id))).scalars().all()
    out: list[dict[str, Any]] = []
    for p in rows:
        eps = (
            await session.execute(
                select(LiveEndpoint).where(LiveEndpoint.platform_id == p.id)
            )
        ).scalars().all()
        active_eps = [e for e in eps if e.status == "active"]
        out.append(
            {
                "id": p.id,
                "displayName": p.display_name,
                "markets": json.loads(p.markets_json or "[]"),
                "liveStrength": p.live_strength,
                "isEnabled": p.is_enabled,
                "endpointCount": len(eps),
                "activeEndpointCount": len(active_eps),
            }
        )
    return out


async def fetch_active_endpoints(
    session: AsyncSession, platform_ids: list[str]
) -> list[LiveEndpoint]:
    if not platform_ids:
        return []
    rows = (
        await session.execute(
            select(LiveEndpoint)
            .where(LiveEndpoint.platform_id.in_(platform_ids))
            .where(LiveEndpoint.status == "active")
        )
    ).scalars().all()
    return list(rows)


def compute_catalog_epoch(platform_ids: list[str], endpoints: list[LiveEndpoint]) -> str:
    parts = sorted(platform_ids)
    for ep in sorted(endpoints, key=lambda e: (e.platform_id, e.id or 0)):
        parts.append(
            f"{ep.platform_id}:{ep.match_type}:{ep.value}:{ep.status}:{ep.role}"
        )
    raw = "|".join(parts)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


def _resolve_targets(endpoints: list[LiveEndpoint]) -> tuple[list[str], list[str], list[str]]:
    """Return fqdn list (for DoH), domain_suffix list, ip_cidr list."""
    fqdns: list[str] = []
    suffixes: list[str] = []
    cidrs: list[str] = []
    seen_f: set[str] = set()
    seen_s: set[str] = set()
    seen_c: set[str] = set()
    for ep in endpoints:
        value = (ep.value or "").strip().lower()
        if not value:
            continue
        mt = (ep.match_type or "").strip().lower()
        if mt == "fqdn":
            if value not in seen_f:
                seen_f.add(value)
                fqdns.append(value)
        elif mt == "domain_suffix":
            if not value.startswith("."):
                value = "." + value
            if value not in seen_s:
                seen_s.add(value)
                suffixes.append(value)
        elif mt == "ip_cidr":
            try:
                net = ipaddress.ip_network(value, strict=False)
                cidr = str(net)
            except ValueError:
                continue
            if cidr not in seen_c:
                seen_c.add(cidr)
                cidrs.append(cidr)
    return fqdns, suffixes, cidrs


def socks_egress_hint(outbound: dict[str, Any]) -> str:
    mode = (outbound.get("mode") or "").strip().lower()
    if mode == "direct":
        return "direct"
    host = (outbound.get("host") or "").strip()
    port = int(outbound.get("port") or 0)
    if host and port:
        return f"{host}:{port}"
    return ""


def expected_detour_tag(line_id: int, outbound: dict[str, Any]) -> str:
    mode = (outbound.get("mode") or "").strip().lower()
    if mode == "direct":
        return "direct"
    return f"client-{line_id}"


def build_live_ip_payload(
    line_id: int,
    *,
    status: str,
    cidrs: list[str],
    domains: list[str],
    domain_suffixes: list[str],
    catalog_epoch: str,
    resolved_at: dt.datetime | None,
    egress_hint: str | None = None,
) -> dict[str, Any]:
    return {
        "lineId": line_id,
        "status": status,
        "cidrs": cidrs,
        "domains": domains,
        "domainSuffixes": domain_suffixes,
        "catalogEpoch": catalog_epoch,
        "resolvedAt": resolved_at.isoformat() if resolved_at else None,
        "egressHint": egress_hint or "",
    }


async def get_line_resolve_row(
    session: AsyncSession, line_id: int
) -> LiveResolveResult | None:
    return await session.get(LiveResolveResult, line_id)


async def build_client_live_ip(
    session: AsyncSession,
    device_line_id: int,
    bound_line: Line,
) -> dict[str, Any] | None:
    """V3: only attach live_ip when line_id matches device binding."""
    if normalize_live_mode(getattr(bound_line, "live_mode", None)) != LIVE_MODE_CATALOG:
        return None
    if device_line_id != bound_line.id:
        return None
    row = await get_line_resolve_row(session, bound_line.id)
    if not row or row.status not in ("ok", "stale"):
        platforms = parse_line_platforms(bound_line)
        if not platforms:
            return None
        endpoints = await fetch_active_endpoints(session, platforms)
        fqdns, suffixes, cidrs = _resolve_targets(endpoints)
        epoch = compute_catalog_epoch(platforms, endpoints)
        return build_live_ip_payload(
            bound_line.id,
            status="pending",
            cidrs=cidrs,
            domains=fqdns,
            domain_suffixes=suffixes,
            catalog_epoch=epoch,
            resolved_at=None,
        )
    try:
        stored = json.loads(row.payload_json or "{}")
    except (json.JSONDecodeError, TypeError):
        stored = {}
    if int(stored.get("lineId") or 0) != bound_line.id:
        return None
    return stored


async def build_node_live_catalog(
    session: AsyncSession,
    lines: list[Line],
    socks_by_id: dict[int, SocksProfile],
) -> dict[str, Any]:
    tasks: list[dict[str, Any]] = []
    epochs: list[str] = []
    for line in lines:
        if not line.is_enabled:
            continue
        if (line.line_type or "forward") != "client":
            continue
        if normalize_live_mode(getattr(line, "live_mode", None)) != LIVE_MODE_CATALOG:
            continue
        platform_ids = parse_line_platforms(line)
        if not platform_ids:
            continue
        endpoints = await fetch_active_endpoints(session, platform_ids)
        fqdns, suffixes, cidrs = _resolve_targets(endpoints)
        epoch = compute_catalog_epoch(platform_ids, endpoints)
        epochs.append(epoch)
        outbound: dict[str, Any] = {"mode": "direct"}
        if line.socks_profile_id is not None:
            sp = socks_by_id.get(line.socks_profile_id)
            if sp:
                outbound = {
                    "mode": "socks",
                    "host": (sp.host or "").strip(),
                    "port": sp.port,
                    "username": ((sp.username or "").strip() or None),
                    "password": ((sp.password or "").strip() or None),
                }
        tasks.append(
            {
                "lineId": line.id,
                "tid": line.tid,
                "liveMode": LIVE_MODE_CATALOG,
                "platformIds": platform_ids,
                "domains": fqdns,
                "domainSuffixes": suffixes,
                "staticCidrs": cidrs,
                "catalogEpoch": epoch,
                "detourTag": expected_detour_tag(line.id, outbound),
                "outbound": outbound,
                "egressHint": socks_egress_hint(outbound),
            }
        )
    catalog_epoch = ""
    if epochs:
        catalog_epoch = hashlib.sha256("|".join(sorted(epochs)).encode()).hexdigest()[:16]
    return {
        "catalogEpoch": catalog_epoch,
        "refreshSeconds": 300,
        "dohUrl": DOH_URL,
        "tasks": tasks,
    }


def validate_resolve_report(
    node_id: int,
    task: dict[str, Any],
    report: dict[str, Any],
) -> tuple[bool, str | None, str | None]:
    """V1–V7 checks. Returns (ok, alert_type, message)."""
    line_id = int(task.get("lineId") or 0)
    if line_id <= 0:
        return False, "live_resolve_invalid", "missing line_id in resolve task"
    if int(report.get("lineId") or 0) != line_id:
        return False, "live_ip_line_mismatch", f"V2 line_id mismatch task={line_id} report={report.get('lineId')}"
    expected_tag = (task.get("detourTag") or "").strip()
    actual_tag = (report.get("detourTag") or "").strip()
    if expected_tag and actual_tag and expected_tag != actual_tag:
        return False, "resolve_vantage_mismatch", f"V1 detour {actual_tag} != {expected_tag}"
    if report.get("skippedUnhealthy"):
        return False, "resolve_vantage_mismatch", "V6 SOCKS unhealthy — resolve skipped"
    expected_hint = (task.get("egressHint") or "").strip()
    actual_hint = (report.get("egressHint") or "").strip()
    if expected_hint and actual_hint and expected_hint != actual_hint:
        return False, "resolve_vantage_mismatch", f"V5 egress_hint {actual_hint} != {expected_hint}"
    if report.get("usedFallbackVantage"):
        return False, "resolve_vantage_mismatch", "V6 fallback vantage used"
    return True, None, None


async def upsert_resolve_result(
    session: AsyncSession,
    *,
    node_id: int,
    line_id: int,
    status: str,
    payload: dict[str, Any],
    egress_hint: str | None,
    catalog_epoch: str | None,
    resolved_at: dt.datetime | None,
) -> LiveResolveResult:
    if int(payload.get("lineId") or 0) != line_id:
        raise ValueError("V2 payload line_id mismatch")
    row = await session.get(LiveResolveResult, line_id)
    now = utc_now()
    if row is None:
        row = LiveResolveResult(line_id=line_id)
    row.node_id = node_id
    row.status = status
    row.payload_json = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    row.egress_hint = egress_hint
    row.catalog_epoch = catalog_epoch
    row.resolved_at = resolved_at
    row.updated_at = now
    session.add(row)
    return row


def merge_report_to_payload(
    task: dict[str, Any],
    report: dict[str, Any],
    *,
    status: str = "ok",
) -> dict[str, Any]:
    static_cidrs = list(task.get("staticCidrs") or [])
    resolved_cidrs = list(report.get("cidrs") or [])
    seen: set[str] = set()
    merged: list[str] = []
    for c in static_cidrs + resolved_cidrs:
        c = str(c).strip()
        if not c or c in seen:
            continue
        seen.add(c)
        merged.append(c)
    resolved_at_raw = report.get("resolvedAt")
    resolved_at: dt.datetime | None = None
    if resolved_at_raw:
        try:
            resolved_at = dt.datetime.fromisoformat(str(resolved_at_raw).replace("Z", "+00:00"))
        except ValueError:
            resolved_at = utc_now()
    else:
        resolved_at = utc_now()
    return build_live_ip_payload(
        int(task["lineId"]),
        status=status,
        cidrs=merged,
        domains=list(task.get("domains") or []),
        domain_suffixes=list(task.get("domainSuffixes") or []),
        catalog_epoch=str(task.get("catalogEpoch") or ""),
        resolved_at=resolved_at,
        egress_hint=str(report.get("egressHint") or task.get("egressHint") or ""),
    )


def endpoint_to_dict(ep: LiveEndpoint) -> dict[str, Any]:
    return {
        "id": ep.id,
        "platformId": ep.platform_id,
        "role": ep.role,
        "matchType": ep.match_type,
        "value": ep.value,
        "confidence": ep.confidence,
        "source": ep.source,
        "status": ep.status,
        "region": ep.region,
        "lastVerifiedAt": ep.last_verified_at.isoformat() if ep.last_verified_at else None,
        "createdAt": ep.created_at.isoformat() if ep.created_at else None,
    }


def capture_candidate_to_dict(row: LiveCaptureCandidate) -> dict[str, Any]:
    evidence: dict[str, Any] = {}
    if row.evidence_json:
        try:
            parsed = json.loads(row.evidence_json)
            if isinstance(parsed, dict):
                evidence = parsed
        except (json.JSONDecodeError, TypeError):
            evidence = {"raw": row.evidence_json}
    return {
        "id": row.id,
        "platformId": row.platform_id,
        "role": row.role,
        "matchType": row.match_type,
        "value": row.value,
        "confidence": row.confidence,
        "source": row.source,
        "status": row.status,
        "notes": row.notes,
        "lineId": row.line_id,
        "evidence": evidence,
        "reviewedBy": row.reviewed_by,
        "reviewedAt": row.reviewed_at.isoformat() if row.reviewed_at else None,
        "endpointId": row.endpoint_id,
        "createdAt": row.created_at.isoformat() if row.created_at else None,
    }


async def find_endpoint_duplicate(
    session: AsyncSession,
    platform_id: str,
    match_type: str,
    value: str,
    *,
    exclude_id: int | None = None,
) -> LiveEndpoint | None:
    stmt = (
        select(LiveEndpoint)
        .where(LiveEndpoint.platform_id == platform_id)
        .where(LiveEndpoint.match_type == match_type)
        .where(LiveEndpoint.value == value)
    )
    if exclude_id is not None:
        stmt = stmt.where(LiveEndpoint.id != exclude_id)
    return (await session.execute(stmt)).scalars().first()
