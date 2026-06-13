from __future__ import annotations

import ipaddress
import json
import os
import subprocess
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from .log_config import read_singbox_log_level
from .routing_mode import read_routing_mode
from .rules_fetch import ensure_local_rules, local_rules_available, rule_set_entries

SINGBOX_CONFIG = Path(os.environ.get("GFC_ETC", "/etc/gfc-client")) / "sing-box.json"
MOSDNS_ADDR = "127.0.0.1:5335"
MOSDNS_PORT = int(MOSDNS_ADDR.split(":")[1])

# Domestic resolvers used by mosdns forward_local — always direct when proxy is active.
DOMESTIC_DNS_CIDRS = [
    "223.5.5.5/32",
    "223.6.6.6/32",
    "119.29.29.29/32",
    "114.114.114.114/32",
]

# International resolvers used by mosdns forward_remote — via proxy when active.
INTL_DNS_CIDRS = [
    "8.8.8.8/32",
    "8.8.4.4/32",
    "1.1.1.1/32",
    "1.0.0.1/32",
]


def _log_block() -> dict[str, Any]:
    return {"level": read_singbox_log_level(), "timestamp": True}


def render_singbox_idle_config() -> dict[str, Any]:
    """No TUN / no hijack — used before line code is activated."""
    return {
        "log": _log_block(),
        "dns": {
            "servers": [{"type": "local", "tag": "local"}],
            "final": "local",
        },
        "inbounds": [],
        "outbounds": [{"type": "direct", "tag": "direct"}],
        "route": {"final": "direct"},
    }


def write_singbox_idle_config(path: Path | None = None) -> Path:
    cfg_path = path or SINGBOX_CONFIG
    cfg_path.parent.mkdir(parents=True, exist_ok=True)
    data = render_singbox_idle_config()
    cfg_path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    return cfg_path


def singbox_config_ok(path: Path | None = None) -> tuple[bool, str]:
    cfg = path or SINGBOX_CONFIG
    if not cfg.is_file():
        return False, "missing config"
    r = subprocess.run(
        ["sing-box", "check", "-c", str(cfg)],
        capture_output=True,
        text=True,
        check=False,
    )
    if r.returncode == 0:
        return True, ""
    return False, (r.stderr or r.stdout or "check failed").strip()


def _route_exclude_addresses() -> list[str]:
    """Keep LAN/management traffic off the TUN default route."""
    exclude = [
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "224.0.0.0/4",
    ]
    lan_cidr = (os.environ.get("GFC_LAN_CIDR") or "192.168.68.0/24").strip()
    if lan_cidr and lan_cidr not in exclude:
        exclude.append(lan_cidr)
    return exclude


def _direct_ip_rule(*hosts: str) -> dict[str, Any] | None:
    cidrs: list[str] = []
    for host in hosts:
        raw = (host or "").strip()
        if not raw:
            continue
        if "://" in raw:
            raw = urlparse(raw).hostname or raw
        raw = raw.split("/", 1)[0]
        if raw.startswith("[") and raw.endswith("]"):
            raw = raw[1:-1]
        try:
            ipaddress.ip_address(raw)
            cidrs.append(f"{raw}/32")
        except ValueError:
            continue
    if not cidrs:
        return None
    return {"ip_cidr": cidrs, "outbound": "direct"}


def _wan_iface() -> str | None:
    iface = (os.environ.get("GFC_WAN_IFACE") or "").strip()
    return iface or None


def _direct_outbound() -> dict[str, Any]:
    """Direct outbound bound to WAN — prevents TUN routing loops (sing-box #4086)."""
    ob: dict[str, Any] = {"type": "direct", "tag": "direct"}
    wan = _wan_iface()
    if wan:
        ob["bind_interface"] = wan
    return ob


def _build_dns_route_rules(*, direct_hosts_rule: dict[str, Any] | None) -> list[dict[str, Any]]:
    """Route rules for DNS without hijack loops to mosdns / upstream resolvers."""
    rules: list[dict[str, Any]] = [
        # sing-box → mosdns and `dig @127.0.0.1 -p 5335` must bypass hijack-dns.
        {"ip_cidr": ["127.0.0.1/32"], "port": [MOSDNS_PORT], "outbound": "direct"},
        # mosdns upstream: domestic resolvers leave via WAN directly.
        {"ip_cidr": DOMESTIC_DNS_CIDRS, "port": [53], "outbound": "direct"},
        # mosdns upstream: international resolvers via proxy (not hijack loop).
        {"ip_cidr": INTL_DNS_CIDRS, "port": [53], "outbound": "proxy"},
    ]
    if direct_hosts_rule:
        rules.append(direct_hosts_rule)
    rules.extend(
        [
            # L4 port hijack before protocol sniff races (sing-box #3878).
            {"port": [53], "action": "hijack-dns"},
            {"ip_is_private": True, "outbound": "direct"},
        ]
    )
    return rules


def _append_split_rules(route_rules: list[dict[str, Any]], *, use_meta_rules: bool) -> None:
    if use_meta_rules:
        route_rules.append({"rule_set": "geoip-cn", "outbound": "direct"})
        route_rules.append({"rule_set": "geosite-cn", "outbound": "direct"})
        route_rules.append({"rule_set": "geosite-geolocation-!cn", "outbound": "proxy"})
        return
    route_rules.append({"domain_suffix": [".cn", ".中国"], "outbound": "direct"})


def render_singbox_config(payload: dict[str, Any]) -> dict[str, Any]:
    node = payload.get("node") or {}
    vless = payload.get("vless") or {}
    proxy_mode = (payload.get("proxyMode") or "gateway").strip().lower()

    address = (node.get("address") or "").strip()
    if not address:
        raise ValueError("node address missing in config payload")

    port = int(node.get("port") or 443)
    uuid = (vless.get("uuid") or "").strip()
    if not uuid:
        raise ValueError("vless uuid missing")

    ensure_local_rules(try_download=False)

    outbounds: list[dict[str, Any]] = [
        _direct_outbound(),
        {
            "type": "vless",
            "tag": "proxy",
            "server": address,
            "server_port": port,
            "uuid": uuid,
            "flow": vless.get("flow") or "xtls-rprx-vision",
            "tls": {
                "enabled": True,
                "server_name": vless.get("serverName") or "www.microsoft.com",
                "utls": {"enabled": True, "fingerprint": "chrome"},
                "reality": {
                    "enabled": True,
                    "public_key": vless.get("publicKey") or "",
                    "short_id": vless.get("shortId") or "",
                },
            },
        },
    ]

    direct_hosts = [address]
    for url in payload.get("controlPlaneServers") or []:
        direct_hosts.append(str(url))
    for env_key in ("SERVER_URL", "SERVER_URL_FALLBACK"):
        if os.environ.get(env_key):
            direct_hosts.append(os.environ[env_key])
    route_rules: list[dict[str, Any]] = _build_dns_route_rules(
        direct_hosts_rule=_direct_ip_rule(*direct_hosts),
    )

    inbounds: list[dict[str, Any]]
    if proxy_mode == "transparent":
        inbounds = [
            {
                "type": "tproxy",
                "tag": "tproxy-in",
                "listen": "0.0.0.0",
                "listen_port": 7895,
            }
        ]
        route_rules.insert(0, {"inbound": "tproxy-in", "action": "sniff"})
    else:
        auto_route = proxy_mode == "gateway"
        tun_inbound: dict[str, Any] = {
            "type": "tun",
            "tag": "tun-in",
            "interface_name": "gfc0",
            "address": ["172.19.0.1/30"],
            "mtu": 9000,
            "auto_route": auto_route,
            "strict_route": auto_route,
            "stack": "mixed",
        }
        if auto_route:
            tun_inbound["auto_redirect"] = True
            tun_inbound["route_address"] = ["0.0.0.0/1", "128.0.0.0/1"]
            tun_inbound["route_exclude_address"] = _route_exclude_addresses()
        inbounds = [tun_inbound]
        route_rules.insert(0, {"inbound": "tun-in", "action": "sniff"})

    routing_mode = (payload.get("routingMode") or read_routing_mode()).strip().lower()
    use_meta_rules = local_rules_available()
    if routing_mode != "global":
        _append_split_rules(route_rules, use_meta_rules=use_meta_rules)
    route_rules.append({"outbound": "proxy"})

    dns_servers: list[dict[str, Any]] = [
        {
            "type": "udp",
            "tag": "mosdns",
            "server": MOSDNS_ADDR.split(":")[0],
            "server_port": int(MOSDNS_ADDR.split(":")[1]),
            "detour": "direct",
        },
    ]

    route_block: dict[str, Any] = {
        "auto_detect_interface": True,
        "final": "proxy",
        "default_domain_resolver": {"server": "local"},
        "rules": route_rules,
    }
    rule_sets = rule_set_entries(allow_remote=False)
    if rule_sets:
        route_block["rule_set"] = rule_sets

    return {
        "log": _log_block(),
        "dns": {
            "servers": dns_servers,
            "final": "mosdns",
            "strategy": "ipv4_only",
        },
        "inbounds": inbounds,
        "outbounds": outbounds,
        "route": route_block,
        "experimental": {
            "cache_file": {"enabled": True, "path": "/var/lib/gfc-client/cache.db"},
        },
    }


def write_singbox_config(payload: dict[str, Any], path: Path | None = None) -> Path:
    cfg_path = path or SINGBOX_CONFIG
    cfg_path.parent.mkdir(parents=True, exist_ok=True)
    data = render_singbox_config(payload)
    cfg_path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    return cfg_path
