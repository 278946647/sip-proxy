from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any

SINGBOX_CONFIG = Path(os.environ.get("GFC_ETC", "/etc/gfc-node")) / "sing-box.json"
DNS_DIRECT_TAG = "dns-direct"
DNS_INTL_DEFAULT = "1.1.1.1"
DNS_DOH_PATH = "/dns-query"


def _intl_dns_server(dataplane: dict[str, Any]) -> str:
    """International DNS (DoH) address — same for SOCKS path and node-direct path."""
    return (
        dataplane.get("dnsIntlServer")
        or dataplane.get("dnsFallbackServer")
        or os.environ.get("GFC_DNS_INTL_SERVER")
        or os.environ.get("GFC_DNS_FALLBACK_SERVER")
        or DNS_INTL_DEFAULT
    ).strip()


def _dns_fallback_enabled(dataplane: dict[str, Any]) -> bool:
    if "dnsFallbackEnabled" in dataplane:
        return bool(dataplane.get("dnsFallbackEnabled"))
    return os.environ.get("GFC_DNS_FALLBACK", "1").strip().lower() not in (
        "0",
        "false",
        "no",
        "off",
    )


def _intl_doh_server(tag: str, server: str, *, detour: str | None = None) -> dict[str, Any]:
    """DoH on 443. No detour => forward node uses its own WAN (direct outbound)."""
    ob: dict[str, Any] = {
        "type": "https",
        "tag": tag,
        "server": server,
        "server_port": 443,
        "path": DNS_DOH_PATH,
    }
    if detour:
        ob["detour"] = detour
    return ob


def singbox_config_ok(path: Path | None = None) -> tuple[bool, str]:
    cfg = path or SINGBOX_CONFIG
    if not cfg.is_file():
        return False, "missing config"
    env = os.environ.copy()
    r = subprocess.run(
        ["sing-box", "check", "-c", str(cfg)],
        capture_output=True,
        text=True,
        env=env,
    )
    if r.returncode == 0:
        return True, ""
    return False, (r.stderr or r.stdout or "check failed").strip()


def render_singbox_config(
    dataplane: dict[str, Any],
    *,
    client_ingress: dict[str, Any] | None = None,
    socks_dns_ok: dict[str, bool] | None = None,
) -> dict[str, Any]:
    rules_cfg = dataplane.get("rules") or []
    tproxy_port = int(dataplane.get("tproxyPort") or 12345)
    fallback_enabled = _dns_fallback_enabled(dataplane)
    intl_dns = _intl_dns_server(dataplane)
    socks_dns_ok = socks_dns_ok or {}

    outbounds: list[dict[str, Any]] = [{"type": "direct", "tag": "direct"}]
    # sing-box 1.13+: sniff must be a route rule action, not an inbound field.
    route_rules: list[dict[str, Any]] = [
        {"inbound": "tproxy-in", "action": "sniff"},
    ]
    dns_servers: list[dict[str, Any]] = []
    dns_rules: list[dict[str, Any]] = []

    for idx, rule in enumerate(rules_cfg):
        tag = f"socks-{rule.get('lineId', idx)}"
        socks = rule["socks"]
        ob: dict[str, Any] = {
            "type": "socks",
            "tag": tag,
            "server": socks["host"],
            "server_port": int(socks["port"]),
            "version": "5",
            # Many SOCKS5 providers reject UDP ASSOCIATE (code=7); tunnel UDP in TCP.
            "udp_over_tcp": {"enabled": True},
        }
        user = (socks.get("username") or "").strip()
        pw = (socks.get("password") or "").strip()
        if user:
            ob["username"] = user
            ob["password"] = pw
        ob["domain_resolver"] = "local-dns"
        outbounds.append(ob)

        dns_tag = f"dns-{tag}"
        proxy_dns_ok = socks_dns_ok.get(tag, True)
        if proxy_dns_ok:
            # International DoH via SOCKS (443; avoids blocked :53 on many SOCKS providers).
            dns_servers.append(_intl_doh_server(dns_tag, intl_dns, detour=tag))
        for cidr in rule.get("sourceCidrs") or []:
            route_rules.append(
                {
                    "source_ip_cidr": [cidr],
                    "action": "route",
                    "outbound": tag,
                }
            )
            if proxy_dns_ok:
                primary_dns = dns_tag
            elif fallback_enabled:
                # SOCKS down: intl DoH via forward-node WAN (direct outbound, no detour).
                primary_dns = DNS_DIRECT_TAG
            else:
                primary_dns = "local-dns"
            dns_rules.append(
                {
                    "source_ip_cidr": [cidr],
                    "action": "route",
                    "server": primary_dns,
                }
            )

    socks_rules = [r for r in route_rules if r.get("action") == "route"]
    final = "direct"
    if dataplane.get("defaultAction") == "drop":
        if socks_rules:
            final = socks_rules[-1]["outbound"]
        else:
            route_rules.append({"action": "reject"})

    # sing-box 1.12+ requires default_domain_resolver when auto_detect_interface is set.
    all_dns_servers: list[dict[str, Any]] = [{"type": "local", "tag": "local-dns"}]
    if fallback_enabled and rules_cfg:
        all_dns_servers.append(_intl_doh_server(DNS_DIRECT_TAG, intl_dns))
    all_dns_servers.extend(dns_servers)
    if rules_cfg:
        # Hijack DNS from TPROXY instead of SOCKS UDP ASSOCIATE (often unsupported).
        route_rules.insert(1, {"protocol": "dns", "action": "hijack-dns"})

    route_block: dict[str, Any] = {
        "rules": route_rules,
        "final": final,
        "auto_detect_interface": True,
        "default_domain_resolver": "local-dns",
    }

    cfg: dict[str, Any] = {
        "log": {"level": "info"},
        "inbounds": [
            {
                "type": "tproxy",
                "tag": "tproxy-in",
                "listen": "0.0.0.0",
                "listen_port": tproxy_port,
            }
        ],
        "outbounds": outbounds,
        "route": route_block,
        "dns": {
            "servers": all_dns_servers,
            "rules": dns_rules,
            "final": DNS_DIRECT_TAG
            if (fallback_enabled and rules_cfg)
            else (all_dns_servers[-1]["tag"] if len(all_dns_servers) > 1 else "local-dns"),
            "strategy": "prefer_ipv4",
            "independent_cache": True,
        },
    }
    _append_client_ingress(
        cfg,
        client_ingress,
        fallback_enabled=fallback_enabled,
        intl_dns=intl_dns,
        socks_dns_ok=socks_dns_ok,
    )
    return cfg


def _parse_reality_dest(dest: str, fallback_host: str) -> tuple[str, int]:
    text = (dest or "").strip() or f"{fallback_host}:443"
    if ":" in text:
        host, port_s = text.rsplit(":", 1)
        try:
            return host.strip(), int(port_s)
        except ValueError:
            return host.strip(), 443
    return text, 443


def _build_client_socks_outbound(tag: str, socks: dict[str, Any]) -> dict[str, Any]:
    ob: dict[str, Any] = {
        "type": "socks",
        "tag": tag,
        "server": socks["host"],
        "server_port": int(socks["port"]),
        "version": "5",
        "udp_over_tcp": {"enabled": True},
        "domain_resolver": "local-dns",
    }
    user = (socks.get("username") or "").strip()
    pw = (socks.get("password") or "").strip()
    if user:
        ob["username"] = user
        ob["password"] = pw
    return ob


def _append_client_ingress(
    cfg: dict[str, Any],
    client_ingress: dict[str, Any] | None,
    *,
    fallback_enabled: bool,
    intl_dns: str,
    socks_dns_ok: dict[str, bool] | None,
) -> None:
    if not client_ingress or not client_ingress.get("enabled"):
        return

    users_cfg = client_ingress.get("users") or []
    if not users_cfg:
        return

    reality = client_ingress.get("reality") or {}
    private_key = (reality.get("privateKey") or "").strip()
    if not private_key:
        return

    server_names = reality.get("serverNames") or ["www.microsoft.com"]
    server_name = (server_names[0] if server_names else "www.microsoft.com").strip()
    short_ids = [s for s in (reality.get("shortIds") or []) if str(s).strip()]
    if not short_ids:
        short_ids = [""]
    listen_port = int(reality.get("listenPort") or 443)
    dest_host, dest_port = _parse_reality_dest(reality.get("dest") or "", server_name)

    vless_users: list[dict[str, Any]] = []
    for user in users_cfg:
        line_id = user.get("lineId")
        name = f"client-{line_id}"
        vless_users.append(
            {
                "name": name,
                "uuid": user["uuid"],
                "flow": user.get("flow") or "xtls-rprx-vision",
            }
        )

    cfg["inbounds"].append(
        {
            "type": "vless",
            "tag": "vless-reality-in",
            "listen": "::",
            "listen_port": listen_port,
            "users": vless_users,
            "tls": {
                "enabled": True,
                "server_name": server_name,
                "reality": {
                    "enabled": True,
                    "handshake": {
                        "server": dest_host,
                        "server_port": dest_port,
                    },
                    "private_key": private_key,
                    "short_id": short_ids,
                },
            },
        }
    )

    route_rules: list[dict[str, Any]] = cfg["route"]["rules"]
    dns_servers: list[dict[str, Any]] = cfg["dns"]["servers"]
    dns_rules: list[dict[str, Any]] = cfg["dns"]["rules"]
    outbounds: list[dict[str, Any]] = cfg["outbounds"]
    socks_dns_ok = socks_dns_ok or {}

    insert_at = 1 if route_rules and route_rules[0].get("inbound") == "tproxy-in" else 0
    route_rules.insert(insert_at, {"inbound": "vless-reality-in", "action": "sniff"})

    for user in users_cfg:
        line_id = user.get("lineId")
        name = f"client-{line_id}"
        tag = name
        outbound = user.get("outbound") or {"mode": "direct"}
        mode = (outbound.get("mode") or "direct").strip().lower()
        route_out = "direct"

        if mode == "socks" and outbound.get("host"):
            if not any(o.get("tag") == tag for o in outbounds):
                outbounds.append(_build_client_socks_outbound(tag, outbound))
            route_out = tag
            proxy_dns_ok = socks_dns_ok.get(tag, True)
            dns_tag = f"dns-{tag}"
            if proxy_dns_ok and not any(s.get("tag") == dns_tag for s in dns_servers):
                dns_servers.append(_intl_doh_server(dns_tag, intl_dns, detour=tag))
            primary_dns = dns_tag if proxy_dns_ok else (
                DNS_DIRECT_TAG if fallback_enabled else "local-dns"
            )
            if primary_dns == DNS_DIRECT_TAG and not any(
                s.get("tag") == DNS_DIRECT_TAG for s in dns_servers
            ):
                dns_servers.append(_intl_doh_server(DNS_DIRECT_TAG, intl_dns))
            dns_rules.append(
                {
                    "inbound": "vless-reality-in",
                    "user": [name],
                    "action": "route",
                    "server": primary_dns,
                }
            )

        route_rules.append(
            {
                "inbound": "vless-reality-in",
                "user": [name],
                "action": "route",
                "outbound": route_out,
            }
        )

    if not any(r.get("action") == "hijack-dns" for r in route_rules):
        hijack_at = min(2, len(route_rules))
        route_rules.insert(hijack_at, {"protocol": "dns", "action": "hijack-dns"})

    cfg["outbounds"] = outbounds
    cfg["route"]["rules"] = route_rules
    cfg["dns"]["servers"] = dns_servers
    cfg["dns"]["rules"] = dns_rules
