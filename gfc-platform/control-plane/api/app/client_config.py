"""Client device config bundle builder."""
from __future__ import annotations

import hashlib
import json
from typing import Any

from .hy2_util import (
    HY2_DEFAULT_PORT,
    HY2_DEFAULT_SNI,
    brutal_mbps,
    ensure_line_hy2_password,
    ensure_node_hy2_config,
    normalize_live_mode,
)
from .line_code import encode_line_code
from .models import ClientDevice, Line, Node, SocksProfile
from .reality_util import REALITY_DEFAULT_PORT, REALITY_DEFAULT_SNI, ensure_node_reality_config
from .server_url_util import public_server_urls


def public_server_url() -> str:
    urls = public_server_urls()
    return urls[0] if urls else "http://127.0.0.1:8181"


def build_line_code_payload(line: Line, node: Node) -> dict[str, Any]:
    """Client line code: control-plane URLs + line binding (one paste after box install)."""
    servers = public_server_urls()
    payload: dict[str, Any] = {
        "v": 2,
        "kind": "line",
        "server": servers[0],
        "lineId": line.id,
        "tid": line.tid,
        "uuid": line.client_uuid,
        "nodeId": node.id,
        "nodeName": node.name,
    }
    if len(servers) > 1:
        payload["serverFallback"] = servers[1]
        payload["servers"] = servers
    return payload


def build_platform_bootstrap_payload() -> dict[str, Any]:
    """Platform-only code: update control-plane URL without changing line binding."""
    servers = public_server_urls()
    payload: dict[str, Any] = {
        "v": 2,
        "kind": "platform",
        "server": servers[0],
    }
    if len(servers) > 1:
        payload["serverFallback"] = servers[1]
        payload["servers"] = servers
    return payload


def refresh_line_code(line: Line, node: Node) -> str:
    return encode_line_code(build_line_code_payload(line, node))


def line_code_fingerprint(code: str) -> str:
    """Short hash for UI / ops to verify line code changed."""
    return hashlib.sha256(code.encode("utf-8")).hexdigest()[:12]


def encode_platform_bootstrap_code() -> str:
    return encode_line_code(build_platform_bootstrap_payload())


def build_client_disabled_payload(
    device: ClientDevice,
    reason: str = "line_disabled",
) -> dict[str, Any]:
    """Direct-egress mode: keep DNS hijack + SNAT, disable proxy dataplane."""
    scheme = (device.routing_scheme or "split").strip().lower()
    if scheme not in ("split", "global"):
        scheme = "split"

    return {
        "deviceId": device.id,
        "deviceName": device.name,
        "lineId": device.line_id,
        "dataplaneMode": "direct",
        "reason": reason,
        "proxyMode": device.proxy_mode or "gateway",
        "routingScheme": scheme,
        "liveMode": "standard",
        "node": {"address": ""},
    }


def build_client_payload(
    device: ClientDevice,
    line: Line,
    node: Node,
    socks: SocksProfile | None,
) -> dict[str, Any]:
    reality = ensure_node_reality_config(node.reality_config_json)
    hy2 = ensure_node_hy2_config(node.hysteria2_config_json)
    live_mode = normalize_live_mode(getattr(line, "live_mode", None))
    hy2_password = ensure_line_hy2_password(getattr(line, "hy2_password", None))
    # Persist generated secrets onto ORM objects when callers flush/commit.
    if getattr(line, "hy2_password", None) != hy2_password:
        line.hy2_password = hy2_password
    try:
        old_hy2 = json.loads(node.hysteria2_config_json or "{}")
    except (json.JSONDecodeError, TypeError):
        old_hy2 = {}
    if not (isinstance(old_hy2, dict) and old_hy2.get("certificate") and old_hy2.get("key")):
        node.hysteria2_config_json = json.dumps(hy2, ensure_ascii=False)

    outbound: dict[str, Any] | None = None
    if socks:
        outbound = {
            "mode": "socks",
            "host": (socks.host or "").strip(),
            "port": socks.port,
            "username": ((socks.username or "").strip() or None),
            "password": ((socks.password or "").strip() or None),
        }
    else:
        outbound = {"mode": "direct"}

    scheme = (device.routing_scheme or "split").strip().lower()
    if scheme not in ("split", "global"):
        scheme = "split"

    brutal_on = bool(getattr(line, "hy2_brutal_enabled", True))
    bw = int(line.bandwidth_mbps or 5)
    hy2_mbps = brutal_mbps(bw, enabled=brutal_on)

    return {
        "deviceId": device.id,
        "deviceName": device.name,
        "lineId": line.id,
        "tid": line.tid,
        "dataplaneMode": "proxy",
        "proxyMode": device.proxy_mode or "gateway",
        "routingScheme": scheme,
        "liveMode": live_mode,
        "controlPlaneServers": public_server_urls(),
        "node": {
            "id": node.id,
            "name": node.name,
            "address": (node.public_ip or "").strip() or None,
            "port": int(reality.get("listenPort") or REALITY_DEFAULT_PORT),
            "hy2Port": int(hy2.get("listenPort") or HY2_DEFAULT_PORT),
        },
        "vless": {
            "uuid": line.client_uuid,
            "flow": "xtls-rprx-vision",
            "serverName": (reality.get("serverNames") or [REALITY_DEFAULT_SNI])[0],
            "publicKey": reality.get("publicKey"),
            "shortId": (reality.get("shortIds") or [""])[0],
        },
        "hysteria2": {
            "password": hy2_password,
            "serverName": hy2.get("serverName") or HY2_DEFAULT_SNI,
            "insecure": True,
            "brutal": brutal_on,
            "upMbps": hy2_mbps if brutal_on else bw,
            "downMbps": hy2_mbps if brutal_on else bw,
            "salamander": bool(hy2.get("salamanderEnabled")),
            "salamanderPassword": (hy2.get("salamanderPassword") or "").strip() or None,
        },
        "outbound": outbound,
        "bandwidthMbps": line.bandwidth_mbps,
        "dns": {
            "intlServer": "1.1.1.1",
            "domesticServer": "223.5.5.5",
        },
    }


def client_payload_version(payload: dict[str, Any]) -> str:
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return hashlib.sha256(raw.encode()).hexdigest()[:16]
