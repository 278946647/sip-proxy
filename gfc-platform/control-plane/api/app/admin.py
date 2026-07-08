from __future__ import annotations

import asyncio
import datetime as dt
import json
import secrets
import string
import uuid
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import delete, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from .active_alerts import compute_active_alerts
from .alerts import send_test_email
from .auth_deps import get_current_user, require_admin
from .db import get_session
from .email_settings import (
    _dict_to_config,
    load_smtp_settings,
    save_smtp_settings,
    smtp_to_public,
)
from .platform_secrets import (
    load_security_settings,
    save_security_settings,
    security_to_public,
)
from .client_config import encode_platform_bootstrap_code, line_code_fingerprint, refresh_line_code
from .models import AlertEvent, ClientDevice, FlowStat, Line, Node, OperationLog, PlatformUser, SocksProfile
from .reality_util import default_reality_config
from .security import hash_password
from .timeutil import ensure_utc, parse_json_field, seconds_ago, utc_now
from .metrics_util import sanitize_last_metrics
from .monitor import node_is_online
from .node_config import build_node_payload
from .node_traffic import build_node_traffic_overview, ensure_billing_defaults
from .schemas import (
    AlertOut,
    DashboardOut,
    FlowStatOut,
    LineCreateIn,
    LineDetailOut,
    LineListItem,
    LineUpdateIn,
    NodeTrafficBillingIn,
    NodeTrafficOverviewOut,
    NodeUpdateIn,
    NodeVpnConfigIn,
    OperationLogOut,
    ClientDeviceDetailOut,
    ClientDeviceListItem,
    ClientDeviceUpdateIn,
    PaginatedLines,
    PaginatedClientDevices,
    SocksProfileIn,
    SocksProfileOut,
    SocksProfileUpdate,
    EmailSettingsIn,
    SecuritySettingsIn,
    StaticRouteIn,
    UserIn,
    UserOut,
    UserUpdateIn,
    VpnPkiIssueIn,
    VpnStaticKeyIssueIn,
)
from .settings import settings
from .socks_parse import format_socks_address, parse_socks_address
from .socks_probe import probe_socks, socks_profile_fields
from .tunnel_pool import (
    TUNNEL_POOL,
    allocate_tunnel_network,
    normalize_tunnel_network,
    parse_tunnel_network,
    tunnel_conflicts,
)
from .vpn_pki import PkiError, generate_static_key, issue_client_cert, pki_status
from .vyos_template import render_vyos_openvpn_server

router = APIRouter(prefix="/admin", tags=["admin"], dependencies=[Depends(get_current_user)])


def _gen_tid() -> str:
    day = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d")
    suffix = "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(6))
    return f"TID-{day}-{suffix}"


def _line_code_response(line: Line, code: str) -> dict[str, str]:
    return {
        "line_code_b32": code,
        "client_uuid": line.client_uuid or "",
        "tid": line.tid,
        "line_id": str(line.id),
        "fingerprint": line_code_fingerprint(code),
    }


async def _sync_line_code(
    session: AsyncSession,
    line: Line,
    node: Node,
    *,
    commit: bool = True,
) -> str:
    """Re-encode line code from current DB fields; persist when stale."""
    code = refresh_line_code(line, node)
    if code != (line.line_code_b32 or ""):
        line.line_code_b32 = code
        session.add(line)
        if commit:
            await session.commit()
    return code


async def _log_op(
    session: AsyncSession,
    username: str,
    action: str,
    target: str,
    detail: str | None = None,
) -> None:
    session.add(
        OperationLog(username=username, action=action, target=target, detail=detail)
    )


def _vpn_summary(vpn_raw: str | None) -> dict[str, Any] | None:
    if not vpn_raw:
        return None
    try:
        vpn = json.loads(vpn_raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(vpn, dict):
        return None
    return {
        "enabled": vpn.get("enabled", True),
        "remote": vpn.get("remote"),
        "port": vpn.get("port", 1194),
        "proto": vpn.get("proto", "udp"),
        "dev": vpn.get("dev", "tun0"),
        "remoteNetworks": vpn.get("remote_networks") or [],
        "tunnelNetwork": vpn.get("tunnel_network"),
        "autoStaticRoutes": vpn.get("auto_static_routes", True),
        "authMode": vpn.get("auth_mode") or "pki",
        "hasCerts": bool(vpn.get("ca") and vpn.get("cert") and vpn.get("key")),
        "hasStaticKey": bool((vpn.get("static_key") or "").strip()),
    }


async def _gather_reserved_networks(
    session: AsyncSession,
    *,
    exclude_node_id: int | None = None,
) -> list[str]:
    """CIDRs that tunnel /30 allocations must not overlap."""
    reserved: list[str] = []
    seen: set[str] = set()

    def add(cidr: str | None) -> None:
        norm = normalize_tunnel_network(cidr) if cidr and "/" in cidr else (cidr or "").strip()
        if not norm or norm in seen:
            return
        seen.add(norm)
        reserved.append(norm)

    nodes = (await session.execute(select(Node))).scalars().all()
    for node in nodes:
        if exclude_node_id is not None and node.id == exclude_node_id:
            continue
        vpn = parse_json_field(node.vpn_config_json)
        if isinstance(vpn, dict):
            add(vpn.get("tunnel_network"))
            for c in vpn.get("remote_networks") or []:
                add(str(c))
        for route in _parse_static_routes_json(node.static_routes_json):
            add(route.get("prefix"))

    lines = (await session.execute(select(Line))).scalars().all()
    for line in lines:
        for c in (line.source_cidrs or "").split(","):
            add(c.strip())

    return reserved


def _resolve_tunnel_network(
    requested: str | None,
    reserved: list[str],
) -> str:
    tunnel = (requested or "").strip()
    if not tunnel:
        return allocate_tunnel_network(reserved)
    reason = tunnel_conflicts(tunnel, reserved)
    if reason:
        raise HTTPException(400, f"隧道网段冲突: {reason}")
    norm = normalize_tunnel_network(tunnel)
    if not norm:
        raise HTTPException(400, "无效的隧道网段 CIDR")
    return norm


def _parse_static_routes_json(raw: str | None) -> list[dict[str, Any]]:
    if not raw:
        return []
    try:
        data = json.loads(raw)
        return data if isinstance(data, list) else []
    except json.JSONDecodeError:
        return []


def _socks_to_out(sp: SocksProfile, *, line_binding_count: int = 0) -> SocksProfileOut:
    return SocksProfileOut(
        id=sp.id,
        name=sp.name,
        host=sp.host,
        port=sp.port,
        username=sp.username,
        password=sp.password,
        country=sp.country,
        channel=sp.channel,
        remark=sp.remark,
        address_display=format_socks_address(sp.host, sp.port, sp.username, sp.password),
        is_healthy=sp.is_healthy,
        line_binding_count=line_binding_count,
        created_at=sp.created_at,
    )


async def _socks_line_binding_counts(session: AsyncSession) -> dict[int, int]:
    rows = (
        await session.execute(
            select(Line.socks_profile_id, func.count(Line.id))
            .where(Line.socks_profile_id.isnot(None))
            .group_by(Line.socks_profile_id)
        )
    ).all()
    return {int(sid): int(cnt) for sid, cnt in rows if sid is not None}


def _line_to_list_item(line: Line) -> LineListItem:
    device = line.client_device
    return LineListItem(
        id=line.id,
        tid=line.tid or f"TID-legacy-{line.id}",
        name=line.name,
        node_id=line.node_id,
        node_name=line.node.name if line.node else "",
        country=line.country,
        bandwidth_mbps=line.bandwidth_mbps,
        remark=line.remark,
        is_enabled=line.is_enabled,
        status=line.status,
        created_at=line.created_at,
        socks_profile_id=line.socks_profile_id,
        socks_name=line.socks_profile.name if line.socks_profile else None,
        line_type=line.line_type or "client",
        client_device_id=device.id if device else None,
        client_device_name=device.name if device else None,
    )


@router.get("/dashboard", response_model=DashboardOut)
async def dashboard(session: AsyncSession = Depends(get_session)) -> DashboardOut:
    now = utc_now()
    offline_threshold = now - dt.timedelta(seconds=settings.node_offline_threshold_seconds)

    nodes = (await session.execute(select(Node))).scalars().all()
    node_online = sum(
        1
        for n in nodes
        if (seen := ensure_utc(n.last_seen_at)) is not None and seen >= offline_threshold
    )

    lines = (await session.execute(select(Line))).scalars().all()
    line_active = sum(1 for l in lines if l.is_enabled)

    socks_rows = (await session.execute(select(SocksProfile))).scalars().all()
    socks_total = len(socks_rows)
    socks_online = sum(1 for s in socks_rows if s.is_healthy)
    socks_offline = socks_total - socks_online

    active = await compute_active_alerts(session)
    alert_open = len(active)
    socks_alert_open = sum(1 for a in active if str(a["type"]).startswith("socks_down_"))

    return DashboardOut(
        node_total=len(nodes),
        node_online=node_online,
        line_total=len(lines),
        line_active=line_active,
        socks_total=socks_total,
        socks_online=socks_online,
        socks_offline=socks_offline,
        alert_open=alert_open,
        socks_alert_open=socks_alert_open,
    )


@router.get("/nodes")
async def list_nodes(session: AsyncSession = Depends(get_session)) -> list[dict[str, Any]]:
    rows = (await session.execute(select(Node).order_by(Node.id.desc()))).scalars().all()
    out: list[dict[str, Any]] = []
    for n in rows:
        seen = ensure_utc(n.last_seen_at)
        ago = seconds_ago(n.last_seen_at)
        online = ago is not None and ago < settings.node_offline_threshold_seconds
        out.append(
            {
                "id": n.id,
                "nodeKey": n.node_key,
                "name": n.name,
                "displayName": f"{n.name} (#{n.id})",
                "region": n.region,
                "country": n.country or n.region,
                "publicIp": n.public_ip,
                "isActive": n.is_active,
                "online": online,
                "lastSeenAt": seen.isoformat() if seen else None,
                "currentConfigVersion": n.current_config_version,
                "connectMode": n.connect_mode,
                "vpnSummary": _vpn_summary(n.vpn_config_json),
                "agentVersion": n.agent_version,
                "lastMetrics": sanitize_last_metrics(
                    parse_json_field(n.last_metrics_json),
                    connect_mode=n.connect_mode,
                ),
                "staticRoutes": _parse_static_routes_json(n.static_routes_json),
                "createdAt": ensure_utc(n.created_at).isoformat() if n.created_at else None,
            }
        )
    return out


@router.get("/nodes/{node_id}")
async def get_node(node_id: int, session: AsyncSession = Depends(get_session)) -> dict[str, Any]:
    n = await session.get(Node, node_id)
    if not n:
        raise HTTPException(404, "node not found")
    seen = ensure_utc(n.last_seen_at)
    return {
        "id": n.id,
        "nodeKey": n.node_key,
        "name": n.name,
        "region": n.region,
        "country": n.country,
        "publicIp": n.public_ip,
        "isActive": n.is_active,
        "connectMode": n.connect_mode,
        "vpnConfig": parse_json_field(n.vpn_config_json),
        "agentVersion": n.agent_version,
        "lastMetrics": sanitize_last_metrics(
            parse_json_field(n.last_metrics_json),
            connect_mode=n.connect_mode,
        ),
        "currentConfigVersion": n.current_config_version,
        "lastSeenAt": seen.isoformat() if seen else None,
        "staticRoutes": _parse_static_routes_json(n.static_routes_json),
    }


@router.put("/nodes/{node_id}/routes")
async def set_node_routes(
    node_id: int,
    body: list[StaticRouteIn],
    session: AsyncSession = Depends(get_session),
    operator: str = Query("admin"),
) -> dict[str, Any]:
    n = await session.get(Node, node_id)
    if not n:
        raise HTTPException(404, "node not found")
    n.static_routes_json = json.dumps(
        [r.model_dump() for r in body], ensure_ascii=False
    )
    n.current_config_version = None
    session.add(n)
    await _log_op(session, operator, "set_node_routes", n.name, f"count={len(body)}")
    await session.commit()
    return await get_node(node_id, session)


@router.delete("/nodes/{node_id}")
async def delete_node(
    node_id: int,
    session: AsyncSession = Depends(get_session),
    operator: str = Query("admin"),
) -> dict[str, bool]:
    n = await session.get(Node, node_id)
    if not n:
        raise HTTPException(404, "node not found")
    line = (
        await session.execute(select(Line).where(Line.node_id == node_id).limit(1))
    ).scalars().first()
    if line:
        raise HTTPException(
            400,
            f"节点仍绑定线路 {line.tid}，请先删除或改绑线路",
        )
    await _log_op(session, operator, "delete_node", n.name, f"id={node_id}")
    await session.delete(n)
    await session.commit()
    return {"ok": True}


@router.patch("/nodes/{node_id}")
async def update_node(
    node_id: int,
    body: NodeUpdateIn,
    session: AsyncSession = Depends(get_session),
    operator: str = Query("admin"),
) -> dict[str, Any]:
    n = await session.get(Node, node_id)
    if not n:
        raise HTTPException(404, "node not found")
    data = body.model_dump(exclude_unset=True)
    if "vpn_config" in data:
        vpn = data.pop("vpn_config")
        n.vpn_config_json = json.dumps(vpn, ensure_ascii=False) if vpn else None
        if vpn and body.connect_mode is None:
            n.connect_mode = "openvpn"
        n.current_config_version = None
    if "static_routes" in data:
        routes = data.pop("static_routes")
        n.static_routes_json = (
            json.dumps(routes, ensure_ascii=False) if routes is not None else None
        )
        n.current_config_version = None
    if "connect_mode" in data:
        n.current_config_version = None
    for k, v in data.items():
        setattr(n, k, v)
    session.add(n)
    await _log_op(session, operator, "update_node", n.name)
    await session.commit()
    return await get_node(node_id, session)


@router.get("/nodes/{node_id}/vpn/tunnel-suggest")
async def suggest_node_vpn_tunnel(
    node_id: int,
    session: AsyncSession = Depends(get_session),
) -> dict[str, Any]:
    n = await session.get(Node, node_id)
    if not n:
        raise HTTPException(404, "node not found")
    reserved = await _gather_reserved_networks(session, exclude_node_id=node_id)
    tunnel = allocate_tunnel_network(reserved)
    vyos_ip, node_ip = parse_tunnel_network(tunnel)
    return {
        "tunnelNetwork": tunnel,
        "vyosTunnelIp": vyos_ip,
        "nodeTunnelIp": node_ip,
        "pool": str(TUNNEL_POOL),
        "reservedCount": len(reserved),
    }


@router.put("/nodes/{node_id}/vpn")
async def set_node_vpn(
    node_id: int,
    body: NodeVpnConfigIn,
    session: AsyncSession = Depends(get_session),
    operator: str = Query("admin"),
) -> dict[str, Any]:
    n = await session.get(Node, node_id)
    if not n:
        raise HTTPException(404, "node not found")
    reserved = await _gather_reserved_networks(session, exclude_node_id=node_id)
    vpn_data = body.model_dump()
    vpn_data["tunnel_network"] = _resolve_tunnel_network(
        vpn_data.get("tunnel_network"),
        reserved,
    )
    n.connect_mode = "openvpn"
    n.vpn_config_json = json.dumps(vpn_data, ensure_ascii=False)
    n.current_config_version = None
    session.add(n)
    await _log_op(session, operator, "set_node_vpn", n.name)
    await session.commit()
    return await get_node(node_id, session)


@router.delete("/nodes/{node_id}/vpn")
async def clear_node_vpn(
    node_id: int,
    session: AsyncSession = Depends(get_session),
    operator: str = Query("admin"),
) -> dict[str, Any]:
    n = await session.get(Node, node_id)
    if not n:
        raise HTTPException(404, "node not found")
    n.vpn_config_json = None
    n.connect_mode = "ethernet"
    n.current_config_version = None
    session.add(n)
    await _log_op(session, operator, "clear_node_vpn", n.name)
    await session.commit()
    return await get_node(node_id, session)


@router.get("/nodes/{node_id}/vpn/vyos")
async def export_vyos_vpn_config(
    node_id: int,
    session: AsyncSession = Depends(get_session),
) -> dict[str, str]:
    n = await session.get(Node, node_id)
    if not n:
        raise HTTPException(404, "node not found")
    vpn = parse_json_field(n.vpn_config_json)
    if not vpn:
        raise HTTPException(400, "节点未配置 OpenVPN")
    lines = (await session.execute(select(Line).where(Line.node_id == node.id))).scalars().all()
    line_cidrs: list[str] = []
    for line in lines:
        if not line.is_enabled:
            continue
        line_cidrs.extend(c.strip() for c in line.source_cidrs.split(",") if c.strip())
    text = render_vyos_openvpn_server(
        node_name=n.name,
        node_public_ip=n.public_ip,
        vpn=vpn,
        line_cidrs=line_cidrs,
    )
    return {"config": text}


@router.get("/vpn/pki/status")
async def vpn_pki_status() -> dict[str, Any]:
    from pathlib import Path

    return pki_status(Path(settings.pki_dir))


@router.post("/nodes/{node_id}/vpn/pki")
async def issue_node_vpn_pki(
    node_id: int,
    body: VpnPkiIssueIn,
    session: AsyncSession = Depends(get_session),
    operator: str = Query("admin"),
) -> dict[str, Any]:
    from pathlib import Path

    n = await session.get(Node, node_id)
    if not n:
        raise HTTPException(404, "node not found")
    cn = (body.common_name or f"gfc-node-{n.id}").strip()
    try:
        material = issue_client_cert(Path(settings.pki_dir), cn)
    except PkiError as e:
        raise HTTPException(400, str(e)) from e

    result: dict[str, Any] = {
        "commonName": cn,
        "caReady": True,
        "saved": False,
    }
    if body.save:
        reserved = await _gather_reserved_networks(session, exclude_node_id=node_id)
        existing = parse_json_field(n.vpn_config_json) or {}
        if not (existing.get("tunnel_network") or "").strip():
            existing["tunnel_network"] = allocate_tunnel_network(reserved)
        existing.update(
            {
                "auth_mode": "pki",
                "ca": material["ca"],
                "cert": material["cert"],
                "key": material["key"],
                "enabled": existing.get("enabled", True),
            }
        )
        n.vpn_config_json = json.dumps(existing, ensure_ascii=False)
        n.connect_mode = "openvpn"
        n.current_config_version = None
        session.add(n)
        await _log_op(session, operator, "issue_node_vpn_pki", n.name, cn)
        await session.commit()
        result["saved"] = True
        result["node"] = await get_node(node_id, session)
    else:
        result["ca"] = material["ca"]
        result["cert"] = material["cert"]
        result["key"] = material["key"]
    return result


@router.post("/nodes/{node_id}/vpn/static-key")
async def issue_node_vpn_static_key(
    node_id: int,
    body: VpnStaticKeyIssueIn,
    session: AsyncSession = Depends(get_session),
    operator: str = Query("admin"),
) -> dict[str, Any]:
    n = await session.get(Node, node_id)
    if not n:
        raise HTTPException(404, "node not found")

    material = generate_static_key()
    result: dict[str, Any] = {"saved": False}
    if body.save:
        reserved = await _gather_reserved_networks(session, exclude_node_id=node_id)
        existing = parse_json_field(n.vpn_config_json) or {}
        if not (existing.get("tunnel_network") or "").strip():
            existing["tunnel_network"] = allocate_tunnel_network(reserved)
        existing.update(
            {
                "auth_mode": "static_key",
                "static_key": material,
                "enabled": existing.get("enabled", True),
            }
        )
        n.vpn_config_json = json.dumps(existing, ensure_ascii=False)
        n.connect_mode = "openvpn"
        n.current_config_version = None
        session.add(n)
        await _log_op(session, operator, "issue_node_vpn_static_key", n.name)
        await session.commit()
        result["saved"] = True
        result["node"] = await get_node(node_id, session)
    else:
        result["static_key"] = material
    return result


@router.get("/nodes/{node_id}/config-preview")
async def preview_node_config(
    node_id: int,
    session: AsyncSession = Depends(get_session),
) -> dict[str, Any]:
    """Preview effective config bundle (incl. auto static routes) before node pull."""
    n = await session.get(Node, node_id)
    if not n:
        raise HTTPException(404, "node not found")
    lines = (await session.execute(select(Line).where(Line.node_id == node.id))).scalars().all()
    socks = (await session.execute(select(SocksProfile))).scalars().all()
    socks_by_id = {s.id: s for s in socks}
    payload = build_node_payload(n, lines, socks_by_id)
    return {"payload": payload}


@router.get("/lines", response_model=PaginatedLines)
async def list_lines(
    session: AsyncSession = Depends(get_session),
    node_id: int | None = None,
    country: str | None = None,
    status: str | None = None,
    is_enabled: bool | None = None,
    bandwidth_mbps: int | None = None,
    search: str | None = None,
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=200),
) -> PaginatedLines:
    stmt = select(Line).options(
        selectinload(Line.node),
        selectinload(Line.socks_profile),
        selectinload(Line.client_device),
    )

    if node_id:
        stmt = stmt.where(Line.node_id == node_id)
    if country:
        stmt = stmt.where(Line.country == country)
    if status:
        stmt = stmt.where(Line.status == status)
    if is_enabled is not None:
        stmt = stmt.where(Line.is_enabled == is_enabled)
    if bandwidth_mbps:
        stmt = stmt.where(Line.bandwidth_mbps == bandwidth_mbps)
    if search:
        q = f"%{search}%"
        stmt = stmt.where(
            or_(Line.tid.ilike(q), Line.name.ilike(q), Line.remark.ilike(q))
        )

    count_base = select(func.count(Line.id))
    if node_id:
        count_base = count_base.where(Line.node_id == node_id)
    if country:
        count_base = count_base.where(Line.country == country)
    if status:
        count_base = count_base.where(Line.status == status)
    if is_enabled is not None:
        count_base = count_base.where(Line.is_enabled == is_enabled)
    if bandwidth_mbps:
        count_base = count_base.where(Line.bandwidth_mbps == bandwidth_mbps)
    if search:
        q = f"%{search}%"
        count_base = count_base.where(
            or_(Line.tid.ilike(q), Line.name.ilike(q), Line.remark.ilike(q))
        )
    total = (await session.execute(count_base)).scalar_one()

    stmt = stmt.order_by(Line.id.desc()).offset((page - 1) * page_size).limit(page_size)
    rows = (await session.execute(stmt)).scalars().all()

    return PaginatedLines(total=total, items=[_line_to_list_item(r) for r in rows])


@router.get("/lines/{line_id}", response_model=LineDetailOut)
async def get_line(line_id: int, session: AsyncSession = Depends(get_session)) -> LineDetailOut:
    stmt = (
        select(Line)
        .where(Line.id == line_id)
        .options(
            selectinload(Line.node),
            selectinload(Line.socks_profile),
            selectinload(Line.client_device),
        )
    )
    line = (await session.execute(stmt)).scalars().first()
    if not line:
        raise HTTPException(404, "line not found")

    sp = line.socks_profile
    node = line.node
    if (line.line_type or "client") == "client" and node:
        await _sync_line_code(session, line, node)
    base = _line_to_list_item(line)
    return LineDetailOut(
        **base.model_dump(),
        source_cidrs=[c.strip() for c in line.source_cidrs.split(",") if c.strip()],
        socks_remark=line.socks_remark,
        created_by=line.created_by,
        socks_host=sp.host if sp else None,
        socks_port=sp.port if sp else None,
        socks_username=sp.username if sp else None,
        socks_password=sp.password if sp else None,
        current_config_version=node.current_config_version if node else None,
        client_uuid=line.client_uuid,
        line_code_b32=line.line_code_b32,
        flow_stats_enabled=line.flow_stats_enabled,
    )


@router.post("/lines", response_model=LineDetailOut)
async def create_line(
    body: LineCreateIn,
    session: AsyncSession = Depends(get_session),
) -> LineDetailOut:
    node = await session.get(Node, body.node_id)
    if not node:
        raise HTTPException(400, "node not found")
    sp = None
    if body.socks_profile_id is not None:
        sp = await session.get(SocksProfile, body.socks_profile_id)
        if not sp:
            raise HTTPException(400, "socks profile not found")

    line_type = body.line_type or "client"
    if line_type == "forward" and not body.source_cidrs:
        raise HTTPException(400, "forward line requires source_cidrs")
    if line_type == "forward" and body.socks_profile_id is None:
        raise HTTPException(400, "forward line requires socks profile")

    tid = _gen_tid()
    name = body.name or tid
    client_uuid = str(uuid.uuid4()) if line_type == "client" else None

    if line_type == "client" and not node.reality_config_json:
        node.reality_config_json = json.dumps(default_reality_config(), ensure_ascii=False)
        session.add(node)

    line = Line(
        tid=tid,
        name=name,
        source_cidrs=",".join(body.source_cidrs),
        node_id=body.node_id,
        socks_profile_id=body.socks_profile_id,
        line_type=line_type,
        client_uuid=client_uuid,
        country=body.country or (node.country or node.region),
        bandwidth_mbps=body.bandwidth_mbps,
        remark=body.remark,
        socks_remark=body.socks_remark,
        status="active",
        is_enabled=True,
        created_by=body.created_by,
    )
    session.add(line)
    await session.flush()
    if line_type == "client":
        await _sync_line_code(session, line, node, commit=False)
    await _log_op(session, body.created_by, "create_line", tid, f"node={node.name}")
    await session.commit()
    await session.refresh(line)
    return await get_line(line.id, session)


@router.patch("/lines/{line_id}", response_model=LineDetailOut)
async def update_line(
    line_id: int,
    body: LineUpdateIn,
    session: AsyncSession = Depends(get_session),
    operator: str = Query("admin"),
) -> LineDetailOut:
    line = await session.get(Line, line_id)
    if not line:
        raise HTTPException(404, "line not found")

    data = body.model_dump(exclude_unset=True)
    if "source_cidrs" in data and data["source_cidrs"] is not None:
        data["source_cidrs"] = ",".join(data["source_cidrs"])
    if "is_enabled" in data:
        data["status"] = "active" if data["is_enabled"] else "inactive"
    for k, v in data.items():
        setattr(line, k, v)
    session.add(line)
    await _log_op(session, operator, "update_line", line.tid)
    await session.commit()
    return await get_line(line_id, session)


@router.delete("/lines/{line_id}")
async def delete_line(
    line_id: int,
    session: AsyncSession = Depends(get_session),
    operator: str = Query("admin"),
) -> dict[str, bool]:
    line = await session.get(Line, line_id)
    if not line:
        raise HTTPException(404, "line not found")
    tid = line.tid
    await session.delete(line)
    await _log_op(session, operator, "delete_line", tid)
    await session.commit()
    return {"ok": True}


@router.get("/socks", response_model=list[SocksProfileOut])
async def list_socks(session: AsyncSession = Depends(get_session)) -> list[SocksProfileOut]:
    rows = (await session.execute(select(SocksProfile).order_by(SocksProfile.id.desc()))).scalars().all()
    bindings = await _socks_line_binding_counts(session)
    return [_socks_to_out(r, line_binding_count=bindings.get(r.id, 0)) for r in rows]


@router.post("/socks", response_model=SocksProfileOut)
async def create_socks(
    body: SocksProfileIn,
    session: AsyncSession = Depends(get_session),
    operator: str = Query("admin"),
) -> SocksProfileOut:
    fields = body.model_dump(exclude={"address"})
    sp = SocksProfile(**fields)
    session.add(sp)
    await _log_op(session, operator, "create_socks", body.name)
    await session.commit()
    await session.refresh(sp)
    return _socks_to_out(sp)


@router.patch("/socks/{socks_id}", response_model=SocksProfileOut)
async def update_socks(
    socks_id: int,
    body: SocksProfileUpdate,
    session: AsyncSession = Depends(get_session),
) -> SocksProfileOut:
    sp = await session.get(SocksProfile, socks_id)
    if not sp:
        raise HTTPException(404, "socks not found")
    data = body.model_dump(exclude_unset=True)
    if data.get("address"):
        p = parse_socks_address(data.pop("address"))
        data["host"] = p["host"]
        data["port"] = p["port"]
        if p.get("username"):
            data["username"] = p["username"]
        if p.get("password"):
            data["password"] = p["password"]
    data.pop("address", None)
    for k, v in data.items():
        setattr(sp, k, v)
    session.add(sp)
    await session.commit()
    await session.refresh(sp)
    return _socks_to_out(sp)


@router.post("/socks/{socks_id}/probe")
async def probe_socks_profile(
    socks_id: int,
    session: AsyncSession = Depends(get_session),
) -> dict[str, Any]:
    sp = await session.get(SocksProfile, socks_id)
    if not sp:
        raise HTTPException(404, "socks not found")
    ok, detail = await asyncio.to_thread(
        probe_socks,
        sp.host,
        sp.port,
        sp.username,
        sp.password,
        probe_url=settings.socks_probe_url,
        timeout_seconds=settings.socks_probe_timeout_seconds,
    )
    sp.is_healthy = ok
    session.add(sp)
    await session.commit()
    return {"ok": ok, "detail": detail, "profile": _socks_to_out(sp).model_dump()}


@router.delete("/socks/{socks_id}")
async def delete_socks(socks_id: int, session: AsyncSession = Depends(get_session)) -> dict[str, bool]:
    sp = await session.get(SocksProfile, socks_id)
    if not sp:
        raise HTTPException(404, "socks not found")
    await session.delete(sp)
    await session.commit()
    return {"ok": True}


@router.delete("/alerts")
async def clear_alerts(
    session: AsyncSession = Depends(get_session),
    operator: str = Depends(get_current_user),
) -> dict[str, int]:
    result = await session.execute(delete(AlertEvent))
    await _log_op(session, operator.username, "clear_alerts", "alert_events")
    await session.commit()
    return {"deleted": result.rowcount or 0}


@router.get("/alerts", response_model=list[AlertOut])
async def list_alerts(
    session: AsyncSession = Depends(get_session),
    limit: int = Query(100, le=500),
    active_only: bool = Query(True, description="Only current faults (default)"),
) -> list[AlertOut]:
    if active_only:
        rows = await compute_active_alerts(session)
        rows = rows[:limit]
        return [
            AlertOut(
                id=int(a["id"]),
                node_id=a.get("node_id"),
                line_id=a.get("line_id"),
                level=a["level"],
                type=a["type"],
                message=a["message"],
                created_at=a["created_at"],
            )
            for a in rows
        ]
    hist = (
        await session.execute(select(AlertEvent).order_by(AlertEvent.id.desc()).limit(limit))
    ).scalars().all()
    return [
        AlertOut(
            id=a.id,
            node_id=a.node_id,
            line_id=a.line_id,
            level=a.level,
            type=a.type,
            message=a.message,
            created_at=a.created_at,
        )
        for a in hist
    ]


@router.get("/lines/{line_id}/flow-stats", response_model=list[FlowStatOut])
async def line_flow_stats(
    line_id: int,
    session: AsyncSession = Depends(get_session),
    hours: int = Query(24, ge=1, le=168),
) -> list[FlowStatOut]:
    line = await session.get(Line, line_id)
    if not line:
        raise HTTPException(404, "line not found")
    cutoff = utc_now() - dt.timedelta(hours=hours)
    rows = (
        await session.execute(
            select(FlowStat)
            .where(FlowStat.line_id == line_id, FlowStat.window_start >= cutoff)
            .order_by(FlowStat.window_start.asc())
        )
    ).scalars().all()
    return [
        FlowStatOut(
            id=f.id,
            node_id=f.node_id,
            line_id=f.line_id,
            window_start=f.window_start,
            window_seconds=f.window_seconds,
            bytes_in=f.bytes_in,
            bytes_out=f.bytes_out,
            active_conns=f.active_conns,
        )
        for f in rows
    ]


@router.get("/flow-stats", response_model=list[FlowStatOut])
async def list_flow_stats(
    session: AsyncSession = Depends(get_session),
    limit: int = Query(200, le=1000),
) -> list[FlowStatOut]:
    rows = (
        await session.execute(select(FlowStat).order_by(FlowStat.id.desc()).limit(limit))
    ).scalars().all()
    return [
        FlowStatOut(
            id=f.id,
            node_id=f.node_id,
            line_id=f.line_id,
            window_start=f.window_start,
            window_seconds=f.window_seconds,
            bytes_in=f.bytes_in,
            bytes_out=f.bytes_out,
            active_conns=f.active_conns,
        )
        for f in rows
    ]


@router.get("/node-traffic/overview", response_model=list[NodeTrafficOverviewOut])
async def node_traffic_overview(
    session: AsyncSession = Depends(get_session),
) -> list[NodeTrafficOverviewOut]:
    nodes = (await session.execute(select(Node).order_by(Node.id.asc()))).scalars().all()
    items: list[NodeTrafficOverviewOut] = []
    for node in nodes:
        row = await build_node_traffic_overview(session, node)
        items.append(NodeTrafficOverviewOut(**row))
    await session.commit()
    return items


@router.patch("/nodes/{node_id}/traffic-billing", response_model=NodeTrafficOverviewOut)
async def update_node_traffic_billing(
    node_id: int,
    body: NodeTrafficBillingIn,
    session: AsyncSession = Depends(get_session),
    operator: str = Query("admin"),
) -> NodeTrafficOverviewOut:
    node = await session.get(Node, node_id)
    if not node:
        raise HTTPException(404, "node not found")
    data = body.model_dump(exclude_unset=True)
    if "monitor_iface" in data:
        node.traffic_monitor_iface = data.pop("monitor_iface")
    for key, val in data.items():
        setattr(node, key, val)
    ensure_billing_defaults(node)
    session.add(node)
    await _log_op(session, operator, "update_node_traffic_billing", node.name)
    await session.commit()
    row = await build_node_traffic_overview(session, node)
    return NodeTrafficOverviewOut(**row)


@router.post("/nodes/{node_id}/traffic-billing/reset-cycle", response_model=NodeTrafficOverviewOut)
async def reset_node_traffic_billing_cycle(
    node_id: int,
    session: AsyncSession = Depends(get_session),
    operator: str = Query("admin"),
) -> NodeTrafficOverviewOut:
    node = await session.get(Node, node_id)
    if not node:
        raise HTTPException(404, "node not found")
    node.traffic_billing_start_at = utc_now()
    node.traffic_correction_bytes = 0
    node.traffic_pending_bytes_in = 0
    node.traffic_pending_bytes_out = 0
    session.add(node)
    await _log_op(session, operator, "reset_node_traffic_cycle", node.name)
    await session.commit()
    row = await build_node_traffic_overview(session, node)
    return NodeTrafficOverviewOut(**row)


@router.get("/settings/email")
async def get_email_settings(session: AsyncSession = Depends(get_session)) -> dict[str, Any]:
    data = await load_smtp_settings(session)
    return smtp_to_public(data)


@router.put("/settings/email", dependencies=[Depends(require_admin)])
async def put_email_settings(
    body: EmailSettingsIn,
    session: AsyncSession = Depends(get_session),
    operator: PlatformUser = Depends(get_current_user),
) -> dict[str, Any]:
    existing = await load_smtp_settings(session) or {}
    stored = {
        "host": body.host.strip(),
        "port": body.port,
        "username": (body.username or "").strip() or None,
        "password": body.password if body.password else existing.get("password"),
        "mail_from": body.mail_from.strip(),
        "mail_to": body.mail_to.strip(),
        "starttls": body.starttls,
    }
    await save_smtp_settings(session, stored)
    await _log_op(session, operator.username, "update_email_settings", "smtp")
    await session.commit()
    return smtp_to_public(stored)


@router.get("/settings/security", dependencies=[Depends(require_admin)])
async def get_security_settings(session: AsyncSession = Depends(get_session)) -> dict[str, Any]:
    data = await load_security_settings(session)
    if not data:
        from .platform_secrets import ensure_platform_secrets

        data = await ensure_platform_secrets(session)
    return security_to_public(data)


@router.put("/settings/security", dependencies=[Depends(require_admin)])
async def put_security_settings(
    body: SecuritySettingsIn,
    session: AsyncSession = Depends(get_session),
    operator: PlatformUser = Depends(get_current_user),
) -> dict[str, Any]:
    if not body.confirm:
        raise HTTPException(400, "请勾选确认后再保存（confirm=true）")
    if not any([body.bootstrap_tokens, body.auth_secret, body.admin_password]):
        raise HTTPException(400, "未提交任何要修改的字段")
    try:
        data = await save_security_settings(
            session,
            bootstrap_tokens=body.bootstrap_tokens,
            auth_secret=body.auth_secret,
            admin_password=body.admin_password,
        )
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    await _log_op(session, operator.username, "update_security_settings", "platform")
    await session.commit()
    return security_to_public(data)


@router.post("/settings/email/test", dependencies=[Depends(require_admin)])
async def test_email_settings(
    session: AsyncSession = Depends(get_session),
) -> dict[str, bool]:
    data = await load_smtp_settings(session)
    cfg = _dict_to_config(data or {})
    if not cfg:
        raise HTTPException(400, "SMTP 未配置，请先保存邮件设置")
    try:
        send_test_email(cfg)
    except OSError as e:
        raise HTTPException(400, f"发送失败: {e}") from e
    return {"ok": True}


@router.get("/users", response_model=list[UserOut])
async def list_users(session: AsyncSession = Depends(get_session)) -> list[UserOut]:
    rows = (await session.execute(select(PlatformUser).order_by(PlatformUser.id))).scalars().all()
    return [
        UserOut(
            id=u.id,
            username=u.username,
            role=u.role,
            is_active=u.is_active,
            created_at=u.created_at,
        )
        for u in rows
    ]


@router.post("/users", response_model=UserOut, dependencies=[Depends(require_admin)])
async def create_user(
    body: UserIn,
    session: AsyncSession = Depends(get_session),
    operator: PlatformUser = Depends(get_current_user),
) -> UserOut:
    exists = (
        await session.execute(
            select(PlatformUser.id).where(PlatformUser.username == body.username.strip())
        )
    ).scalar_one_or_none()
    if exists:
        raise HTTPException(400, "username already exists")
    u = PlatformUser(
        username=body.username.strip(),
        role=body.role,
        password_hash=hash_password(body.password),
    )
    session.add(u)
    await _log_op(session, operator.username, "create_user", u.username)
    await session.commit()
    await session.refresh(u)
    return UserOut(
        id=u.id,
        username=u.username,
        role=u.role,
        is_active=u.is_active,
        created_at=u.created_at,
    )


@router.patch("/users/{user_id}", response_model=UserOut, dependencies=[Depends(require_admin)])
async def update_user(
    user_id: int,
    body: UserUpdateIn,
    session: AsyncSession = Depends(get_session),
    operator: PlatformUser = Depends(get_current_user),
) -> UserOut:
    u = await session.get(PlatformUser, user_id)
    if not u:
        raise HTTPException(404, "user not found")
    data = body.model_dump(exclude_unset=True)
    if "password" in data:
        u.password_hash = hash_password(data.pop("password"))
    for k, v in data.items():
        setattr(u, k, v)
    session.add(u)
    await _log_op(session, operator.username, "update_user", u.username)
    await session.commit()
    await session.refresh(u)
    return UserOut(
        id=u.id,
        username=u.username,
        role=u.role,
        is_active=u.is_active,
        created_at=u.created_at,
    )


@router.get("/operation-logs", response_model=list[OperationLogOut])
async def list_operation_logs(
    session: AsyncSession = Depends(get_session),
    limit: int = Query(200, le=500),
) -> list[OperationLogOut]:
    rows = (
        await session.execute(
            select(OperationLog).order_by(OperationLog.id.desc()).limit(limit)
        )
    ).scalars().all()
    return [
        OperationLogOut(
            id=o.id,
            username=o.username,
            action=o.action,
            target=o.target,
            detail=o.detail,
            created_at=o.created_at,
        )
        for o in rows
    ]


@router.get("/meta/countries")
async def list_countries(session: AsyncSession = Depends(get_session)) -> list[str]:
    rows = (await session.execute(select(Line.country).distinct())).all()
    return sorted({r[0] for r in rows if r[0]})


def _client_device_online(device: ClientDevice) -> bool:
    if not device.last_seen_at:
        return False
    return seconds_ago(device.last_seen_at) <= settings.client_offline_threshold_seconds


def _derive_client_device_states(
    device: ClientDevice,
) -> tuple[str, str, str | None, bool | None]:
    online = _client_device_online(device)
    management_state = "online" if online else "offline"
    if not online:
        return management_state, "unknown", None, None

    line = device.line
    if device.line_id is None:
        return management_state, "unbound", "line_unbound", None
    if line is None:
        return management_state, "suspended", "line_deleted", None
    if not line.is_enabled:
        return management_state, "suspended", "line_disabled", False

    node = line.node
    if node and not node_is_online(node):
        return management_state, "degraded", "node_offline", True

    if device.last_metrics_json:
        try:
            metrics = json.loads(device.last_metrics_json)
            agent_state = str(metrics.get("agent_state") or "").strip()
            if agent_state and agent_state != "active":
                return management_state, "degraded", "agent_not_active", True
        except json.JSONDecodeError:
            pass

    return management_state, "active", None, True


def _client_device_list_item(device: ClientDevice) -> ClientDeviceListItem:
    line = device.line
    management_state, service_state, service_reason, line_enabled = _derive_client_device_states(device)
    return ClientDeviceListItem(
        id=device.id,
        name=device.name,
        device_key=device.device_key,
        lan_mac=device.lan_mac,
        device_id=device.device_id,
        line_id=device.line_id,
        line_tid=line.tid if line else None,
        reverse_ssh_port=device.reverse_ssh_port,
        proxy_mode=device.proxy_mode or "gateway",
        online=_client_device_online(device),
        management_state=management_state,
        service_state=service_state,
        service_reason=service_reason,
        line_enabled=line_enabled,
        last_seen_at=device.last_seen_at,
        agent_version=device.agent_version,
        created_at=device.created_at,
    )


@router.get("/client-devices", response_model=PaginatedClientDevices)
async def list_client_devices(
    session: AsyncSession = Depends(get_session),
    search: str | None = None,
    online: bool | None = None,
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=200),
) -> PaginatedClientDevices:
    stmt = select(ClientDevice).options(
        selectinload(ClientDevice.line).selectinload(Line.node)
    )
    count_base = select(func.count(ClientDevice.id))

    if search:
        q = f"%{search}%"
        filt = or_(
            ClientDevice.name.ilike(q),
            ClientDevice.device_key.ilike(q),
            ClientDevice.device_id.ilike(q),
            ClientDevice.lan_mac.ilike(q),
        )
        stmt = stmt.where(filt)
        count_base = count_base.where(filt)

    rows = (await session.execute(stmt.order_by(ClientDevice.id.desc()))).scalars().all()
    items = [_client_device_list_item(d) for d in rows]
    if online is not None:
        items = [i for i in items if i.online == online]
    total = len(items)
    start = (page - 1) * page_size
    page_items = items[start : start + page_size]
    return PaginatedClientDevices(total=total, items=page_items)


@router.get("/client-devices/{device_id}", response_model=ClientDeviceDetailOut)
async def get_client_device(
    device_id: int,
    session: AsyncSession = Depends(get_session),
) -> ClientDeviceDetailOut:
    stmt = (
        select(ClientDevice)
        .where(ClientDevice.id == device_id)
        .options(selectinload(ClientDevice.line).selectinload(Line.node))
    )
    device = (await session.execute(stmt)).scalars().first()
    if not device:
        raise HTTPException(404, "client device not found")

    base = _client_device_list_item(device)
    metrics = None
    if device.last_metrics_json:
        try:
            metrics = json.loads(device.last_metrics_json)
        except json.JSONDecodeError:
            metrics = None

    line = device.line
    ssh_url = None
    if device.reverse_ssh_port:
        ssh_url = f"ssh://127.0.0.1:{device.reverse_ssh_port}"

    return ClientDeviceDetailOut(
        **base.model_dump(),
        metrics=metrics,
        line_name=line.name if line else None,
        node_name=line.node.name if line and line.node else None,
        ssh_connect_url=ssh_url,
    )


@router.patch("/client-devices/{device_id}", response_model=ClientDeviceDetailOut)
async def update_client_device(
    device_id: int,
    body: ClientDeviceUpdateIn,
    session: AsyncSession = Depends(get_session),
    operator: str = Query("admin"),
) -> ClientDeviceDetailOut:
    device = await session.get(ClientDevice, device_id)
    if not device:
        raise HTTPException(404, "client device not found")

    data = body.model_dump(exclude_unset=True)
    if "line_id" in data and data["line_id"] is not None:
        line = await session.get(Line, data["line_id"])
        if not line:
            raise HTTPException(400, "line not found")
        bound = (
            await session.execute(
                select(ClientDevice).where(
                    ClientDevice.line_id == data["line_id"],
                    ClientDevice.id != device_id,
                )
            )
        ).scalars().first()
        if bound:
            raise HTTPException(409, "line already bound to another device")

    for k, v in data.items():
        setattr(device, k, v)
    session.add(device)
    await _log_op(session, operator, "update_client_device", device.device_key)
    await session.commit()
    return await get_client_device(device_id, session)


@router.delete("/client-devices/{device_id}")
async def delete_client_device(
    device_id: int,
    session: AsyncSession = Depends(get_session),
    operator: str = Query("admin"),
) -> dict[str, str | bool]:
    device = await session.get(ClientDevice, device_id)
    if not device:
        raise HTTPException(404, "client device not found")

    label = device.name or device.device_key
    await _log_op(session, operator, "delete_client_device", label, f"id={device_id}")
    await session.delete(device)
    await session.commit()
    return {
        "ok": True,
        "message": "设备记录已删除；客户端仍在线时会通过线路码自动重新注册",
    }


@router.get("/lines/{line_id}/line-code")
async def get_line_code(
    line_id: int,
    session: AsyncSession = Depends(get_session),
) -> dict[str, str]:
    stmt = select(Line).where(Line.id == line_id).options(selectinload(Line.node))
    line = (await session.execute(stmt)).scalars().first()
    if not line or not line.node:
        raise HTTPException(404, "line not found")
    if (line.line_type or "client") != "client":
        raise HTTPException(400, "not a client line")
    code = await _sync_line_code(session, line, line.node)
    return _line_code_response(line, code)


@router.post("/lines/{line_id}/line-code/refresh")
async def refresh_line_code_endpoint(
    line_id: int,
    rotate_uuid: bool = Query(False, description="生成新 UUID 并使旧线码失效"),
    session: AsyncSession = Depends(get_session),
    operator: str = Query("admin"),
) -> dict[str, str]:
    """Re-encode line code from current DB fields (uuid/node/server). Fixes uuid mismatch."""
    stmt = select(Line).where(Line.id == line_id).options(selectinload(Line.node))
    line = (await session.execute(stmt)).scalars().first()
    if not line or not line.node:
        raise HTTPException(404, "line not found")
    if (line.line_type or "client") != "client":
        raise HTTPException(400, "not a client line")
    if rotate_uuid or not line.client_uuid:
        line.client_uuid = str(uuid.uuid4())
    code = await _sync_line_code(session, line, line.node, commit=False)
    await _log_op(session, operator, "refresh_line_code", line.tid)
    await session.commit()
    return _line_code_response(line, code)


@router.get("/platform/bootstrap-code")
async def get_platform_bootstrap_code() -> dict[str, str]:
    """Platform-only flash code (control-plane URL); client line codes already embed the same URLs."""
    return {"bootstrap_code_b32": encode_platform_bootstrap_code()}
