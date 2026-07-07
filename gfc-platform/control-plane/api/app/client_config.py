"""Client device config bundle builder."""
from __future__ import annotations

import hashlib
import json
from typing import Any

from .line_code import encode_line_code
from .models import ClientDevice, Line, Node, SocksProfile
from .reality_util import REALITY_DEFAULT_PORT, REALITY_DEFAULT_SNI, ensure_node_reality_config
from .server_url_util import public_server_urls


def public_server_url() -> str:
    urls = public_server_urls()
    return urls[0] if urls else "http://127.0.0.1:8080"


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
    return {
        "deviceId": device.id,
        "deviceName": device.name,
        "lineId": device.line_id,
        "dataplaneMode": "direct",
        "reason": reason,
        "proxyMode": device.proxy_mode or "gateway",
        "node": {"address": ""},
    }


def build_client_payload(
    device: ClientDevice,
    line: Line,
    node: Node,
    socks: SocksProfile | None,
) -> dict[str, Any]:
    reality = ensure_node_reality_config(node.reality_config_json)
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

    return {
        "deviceId": device.id,
        "deviceName": device.name,
        "lineId": line.id,
        "tid": line.tid,
        "dataplaneMode": "proxy",
        "proxyMode": device.proxy_mode or "gateway",
        "node": {
            "id": node.id,
            "name": node.name,
            "address": (node.public_ip or "").strip() or None,
            "port": int(reality.get("listenPort") or REALITY_DEFAULT_PORT),
        },
        "vless": {
            "uuid": line.client_uuid,
            "flow": "xtls-rprx-vision",
            "serverName": (reality.get("serverNames") or [REALITY_DEFAULT_SNI])[0],
            "publicKey": reality.get("publicKey"),
            "shortId": (reality.get("shortIds") or [""])[0],
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
