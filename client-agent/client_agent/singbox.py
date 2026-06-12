from __future__ import annotations

import ipaddress
import json
import os
import subprocess
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from .routing_mode import read_routing_mode

SINGBOX_CONFIG = Path(os.environ.get("GFC_ETC", "/etc/gfc-client")) / "sing-box.json"
MOSDNS_ADDR = "127.0.0.1:5335"
DOMAIN_RESOLVER: dict[str, str] = {"server": "mosdns"}


def render_singbox_idle_config() -> dict[str, Any]:
    """No TUN / no hijack — used before line code is activated."""
    return {
        "log": {"level": "info", "timestamp": True},
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


def render_singbox_config(payload: dict[str, Any]) -> dict[str, Any]:
    node = payload.get("node") or {}
    vless = payload.get("vless") or {}
    proxy_mode = (payload.get("proxyMode") or "gateway").strip().lower()
    dns_cfg = payload.get("dns") or {}

    address = (node.get("address") or "").strip()
    if not address:
        raise ValueError("node address missing in config payload")

    port = int(node.get("port") or 443)
    uuid = (vless.get("uuid") or "").strip()
    if not uuid:
        raise ValueError("vless uuid missing")

    outbounds: list[dict[str, Any]] = [
        {"type": "direct", "tag": "direct", "domain_resolver": DOMAIN_RESOLVER},
        {
            "type": "vless",
            "tag": "proxy",
            "server": address,
            "server_port": port,
            "uuid": uuid,
            "flow": vless.get("flow") or "xtls-rprx-vision",
            "domain_resolver": DOMAIN_RESOLVER,
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

    route_rules: list[dict[str, Any]] = [
        {"protocol": "dns", "action": "hijack-dns"},
        {"ip_is_private": True, "outbound": "direct"},
        {"ip_cidr": ["223.5.5.5/32", "223.6.6.6/32", "119.29.29.29/32", "8.8.8.8/32", "1.1.1.1/32"], "outbound": "direct"},
    ]
    direct_hosts = [address]
    for url in payload.get("controlPlaneServers") or []:
        direct_hosts.append(str(url))
    for env_key in ("SERVER_URL", "SERVER_URL_FALLBACK"):
        if os.environ.get(env_key):
            direct_hosts.append(os.environ[env_key])
    direct_rule = _direct_ip_rule(*direct_hosts)
    if direct_rule:
        route_rules.insert(2, direct_rule)

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
            # Capture local + forwarded LAN traffic (gateway mode). Without this,
            # only host-originated packets use TUN; LAN clients NAT straight to WAN.
            tun_inbound["auto_redirect"] = True
            tun_inbound["route_address"] = ["0.0.0.0/1", "128.0.0.0/1"]
            tun_inbound["route_exclude_address"] = _route_exclude_addresses()
        inbounds = [tun_inbound]
        route_rules.insert(0, {"inbound": "tun-in", "action": "sniff"})

    routing_mode = (payload.get("routingMode") or read_routing_mode()).strip().lower()
    if routing_mode != "global":
        domestic_suffixes = [".cn", ".中国"]
        route_rules.append({"domain_suffix": domestic_suffixes, "outbound": "direct"})
    route_rules.append({"outbound": "proxy"})

    # sing-box 1.13+: 仅保留一个 DNS server，否则 check 强制要求 domain_resolver
    dns_servers: list[dict[str, Any]] = [
        {
            "type": "udp",
            "tag": "mosdns",
            "server": MOSDNS_ADDR.split(":")[0],
            "server_port": int(MOSDNS_ADDR.split(":")[1]),
            "detour": "direct",
        },
    ]

    return {
        "log": {"level": "info", "timestamp": True},
        "dns": {
            "servers": dns_servers,
            "final": "mosdns",
            "strategy": "ipv4_only",
        },
        "inbounds": inbounds,
        "outbounds": outbounds,
        "route": {
            "auto_detect_interface": True,
            "final": "proxy",
            "default_domain_resolver": DOMAIN_RESOLVER,
            "rules": route_rules,
        },
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
