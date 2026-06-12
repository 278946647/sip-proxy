from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any

from .routing_mode import read_routing_mode

SINGBOX_CONFIG = Path(os.environ.get("GFC_ETC", "/etc/gfc-client")) / "sing-box.json"
MOSDNS_ADDR = "127.0.0.1:5335"
DOMAIN_RESOLVER: dict[str, str] = {"server": "mosdns"}


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
        {"ip_cidr": ["223.5.5.5/32", "223.6.6.6/32", "119.29.29.29/32"], "outbound": "direct"},
    ]

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
        inbounds = [
            {
                "type": "tun",
                "tag": "tun-in",
                "interface_name": "gfc0",
                "address": ["172.19.0.1/30"],
                "mtu": 9000,
                "auto_route": auto_route,
                "strict_route": auto_route,
                "stack": "mixed",
            }
        ]
        route_rules.insert(0, {"inbound": "tun-in", "action": "sniff"})

    routing_mode = (payload.get("routingMode") or read_routing_mode()).strip().lower()
    if routing_mode != "global":
        domestic_suffixes = [".cn", ".中国"]
        route_rules.append({"domain_suffix": domestic_suffixes, "outbound": "direct"})
    route_rules.append({"outbound": "proxy"})

    dns_servers: list[dict[str, Any]] = [
        {
            "type": "udp",
            "tag": "mosdns",
            "server": MOSDNS_ADDR.split(":")[0],
            "server_port": int(MOSDNS_ADDR.split(":")[1]),
            "detour": "direct",
        },
        {
            "type": "udp",
            "tag": "domestic-fallback",
            "server": (dns_cfg.get("domesticServer") or "223.5.5.5").strip(),
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
