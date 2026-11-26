from __future__ import annotations

import hashlib
import ipaddress
import json
import uuid
from typing import Any

from .models import AwgPeer, Line, Node, SocksProfile
from .awg_util import decrypt_secret, ensure_node_awg_config
from .platform_secrets import get_primary_bootstrap_token
from .reality_util import ensure_node_reality_config
from .hy2_util import (
    ensure_line_hy2_password,
    ensure_node_hy2_config,
    normalize_live_mode,
)
from .live_catalog import parse_line_platforms


def _collect_line_cidrs(lines: list[Line]) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for line in lines:
        if not line.is_enabled:
            continue
        if (line.line_type or "client") == "client":
            continue
        for cidr in (line.source_cidrs or "").split(","):
            c = cidr.strip()
            if c and c not in seen:
                seen.add(c)
                out.append(c)
    return out


def _merge_static_routes(
    manual: list[dict[str, Any]],
    auto_prefixes: list[str],
    device: str,
) -> list[dict[str, Any]]:
    """OpenVPN auto return routes override manual entries for the same prefix."""
    auto_set = {p.strip() for p in auto_prefixes if (p or "").strip()}
    merged: list[dict[str, Any]] = []
    for r in manual:
        prefix = (r.get("prefix") or "").strip()
        if prefix and prefix in auto_set:
            continue
        merged.append(dict(r))
    existing = {(r.get("prefix") or "").strip() for r in merged}
    for prefix in auto_prefixes:
        p = prefix.strip()
        if not p:
            continue
        merged.append(
            {
                "prefix": p,
                "device": device,
                "comment": "auto: openvpn return path",
            }
        )
        existing.add(p)
    return merged


def _build_forward_rules(
    lines: list[Line],
    socks_by_id: dict[int, SocksProfile],
) -> list[dict[str, Any]]:
    rules: list[dict[str, Any]] = []
    for line in lines:
        if not line.is_enabled:
            continue
        if (line.line_type or "client") == "client":
            continue
        if line.socks_profile_id is None:
            continue
        sp = socks_by_id.get(line.socks_profile_id)
        if not sp:
            continue
        cidrs = [c.strip() for c in (line.source_cidrs or "").split(",") if c.strip()]
        rules.append(
            {
                "lineId": line.id,
                "tid": line.tid,
                "lineName": line.name,
                "sourceCidrs": cidrs,
                "socks": {
                    "host": (sp.host or "").strip(),
                    "port": sp.port,
                    "username": ((sp.username or "").strip() or None),
                    "password": ((sp.password or "").strip() or None),
                    "udpOverTcp": line.socks_udp_over_tcp,
                },
            }
        )
    return rules


def _build_client_ingress(
    lines: list[Line],
    socks_by_id: dict[int, SocksProfile],
) -> dict[str, Any]:
    users: list[dict[str, Any]] = []
    for line in lines:
        if not line.is_enabled:
            continue
        if (line.line_type or "forward") != "client":
            continue
        if not line.client_uuid:
            continue
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
                    "udpOverTcp": line.socks_udp_over_tcp,
                }
        hy2_password = ensure_line_hy2_password(getattr(line, "hy2_password", None))
        if getattr(line, "hy2_password", None) != hy2_password:
            line.hy2_password = hy2_password
        users.append(
            {
                "lineId": line.id,
                "tid": line.tid,
                "lineName": line.name,
                "uuid": line.client_uuid,
                "flow": "xtls-rprx-vision",
                "bandwidthMbps": line.bandwidth_mbps,
                "liveMode": normalize_live_mode(getattr(line, "live_mode", None)),
                "livePlatforms": parse_line_platforms(line),
                "hy2Password": hy2_password,
                "hy2Brutal": bool(getattr(line, "hy2_brutal_enabled", True)),
                "transport": getattr(line, "transport", None) or "reality",
                "awgInnerIp": getattr(line, "awg_inner_ip", None),
                "outbound": outbound,
            }
        )
    return {"users": users}


def _collect_bypass_cidrs_for_node(
    node: Node,
    lines: list[Line],
    socks_by_id: dict[int, SocksProfile],
) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    public_ip = (node.public_ip or "").strip()
    if public_ip:
        try:
            ipaddress.ip_address(public_ip)
            cidr = f"{public_ip}/32"
            seen.add(cidr)
            out.append(cidr)
        except ValueError:
            pass
    for line in lines:
        if not line.is_enabled:
            continue
        if line.socks_profile_id is None:
            continue
        sp = socks_by_id.get(line.socks_profile_id)
        if not sp:
            continue
        host = (sp.host or "").strip()
        if not host:
            continue
        try:
            ipaddress.ip_address(host)
            cidr = f"{host}/32"
        except ValueError:
            continue
        if cidr not in seen:
            seen.add(cidr)
            out.append(cidr)
    return out


def build_node_payload(
    node: Node,
    lines: list[Line],
    socks_by_id: dict[int, SocksProfile],
    live_catalog: dict[str, Any] | None = None,
    awg_peers: list[AwgPeer] | None = None,
) -> dict[str, Any]:
    rules = _build_forward_rules(lines, socks_by_id)
    client_ingress = _build_client_ingress(lines, socks_by_id)
    reality = ensure_node_reality_config(node.reality_config_json)
    hy2 = ensure_node_hy2_config(node.hysteria2_config_json)
    awg_raw = getattr(node, "awg_config_json", None)
    if awg_raw or awg_peers:
        awg = ensure_node_awg_config(
            awg_raw,
            getattr(node, "awg_pool_cidr", None) or "10.66.0.0/16",
        )
    else:
        awg = {
            "enabled": False,
            "iface": "awg0",
            "listenPort": 51820,
            "serverInnerIp": "",
            "serverPrivateKey": "",
            "serverPublicKey": "",
            "mtu": 1408,
            "paramsVersion": 1,
            "obfuscation": {},
            "checksum": "",
        }
    awg_peer_rows: list[dict[str, Any]] = []
    for peer in awg_peers or []:
        if (peer.status or "active") != "active":
            continue
        awg_peer_rows.append(
            {
                "lineId": peer.line_id,
                "innerIp": peer.inner_ip,
                "publicKey": peer.public_key,
                "presharedKey": decrypt_secret(peer.preshared_key_enc) or None,
            }
        )
    awg_enabled = bool(awg.get("enabled", True) and awg_peer_rows)
    try:
        old_hy2 = json.loads(node.hysteria2_config_json or "{}")
    except (json.JSONDecodeError, TypeError):
        old_hy2 = {}
    if not (isinstance(old_hy2, dict) and old_hy2.get("certificate") and old_hy2.get("key")):
        node.hysteria2_config_json = json.dumps(hy2, ensure_ascii=False)
    bypass_cidrs = _collect_bypass_cidrs_for_node(node, lines, socks_by_id)

    connect_mode = node.connect_mode or "ethernet"
    vpn: dict[str, Any] | None = None
    if connect_mode == "openvpn" and node.vpn_config_json:
        try:
            vpn = json.loads(node.vpn_config_json)
        except json.JSONDecodeError:
            vpn = None

    static_routes: list[dict[str, Any]] = []
    if node.static_routes_json:
        try:
            raw = json.loads(node.static_routes_json)
            if isinstance(raw, list):
                static_routes = raw
        except json.JSONDecodeError:
            static_routes = []

    tproxy_iface: str | None = None
    if connect_mode == "openvpn" and vpn and vpn.get("enabled", True):
        tproxy_iface = (vpn.get("dev") or "tun0").strip() or "tun0"
        if vpn.get("auto_static_routes", True):
            auto_cidrs = list(vpn.get("remote_networks") or [])
            for c in _collect_line_cidrs(lines):
                if c not in auto_cidrs:
                    auto_cidrs.append(c)
            static_routes = _merge_static_routes(static_routes, auto_cidrs, tproxy_iface)

    if awg_enabled and not tproxy_iface:
        # No other tunnel ingress; AWG decap traffic is the TPROXY ingress.
        tproxy_iface = str(awg.get("iface") or "awg0")

    if client_ingress["users"] and not node.reality_config_json:
        pass  # persisted when line is created on control plane

    payload: dict[str, Any] = {
        "configSchemaVersion": 2,
        "nodeId": node.id,
        "nodeName": node.name,
        "connectMode": connect_mode,
        "transport": "awg" if awg_enabled else "reality",
        "vpn": vpn,
        "tproxyIface": tproxy_iface,
        "awg": {
            "enabled": awg_enabled,
            "iface": str(awg.get("iface") or "awg0"),
            "listenPort": int(awg.get("listenPort") or 51820),
            "serverInnerIp": str(awg.get("serverInnerIp") or ""),
            "serverPrivateKey": str(awg.get("serverPrivateKey") or ""),
            "serverPublicKey": str(awg.get("serverPublicKey") or ""),
            "mtu": int(awg.get("mtu") or 1408),
            "paramsVersion": int(awg.get("paramsVersion") or 1),
            "obfuscation": dict(awg.get("obfuscation") or {}),
            "checksum": str(awg.get("checksum") or ""),
            "peers": awg_peer_rows,
        },
        "bootstrapToken": get_primary_bootstrap_token(),
        "staticRoutes": static_routes,
        "clientIngress": {
            "enabled": bool(client_ingress["users"]),
            "reality": reality,
            "hysteria2": hy2,
            "users": client_ingress["users"],
        },
        "dataplane": {
            "tproxyPort": 12345,
            "defaultAction": "drop",
            "rules": rules,
            "bypassCidrs": bypass_cidrs,
            "dnsFallbackEnabled": True,
            "dnsIntlServer": "1.1.1.1",
        },
    }
    if live_catalog:
        payload["liveCatalog"] = live_catalog
    return payload


def payload_version(payload: dict[str, Any]) -> str:
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return hashlib.sha256(raw.encode()).hexdigest()[:16]
