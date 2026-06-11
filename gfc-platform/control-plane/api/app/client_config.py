"""Client device config bundle builder."""
from __future__ import annotations

import hashlib
import json
import os
from typing import Any

from .line_code import encode_line_code
from .models import ClientDevice, Line, Node, SocksProfile
from .reality_util import ensure_node_reality_config
from .settings import settings


def public_server_url() -> str:
    from .settings import settings

    env = (os.getenv("GFC_PUBLIC_URL") or "").strip()
    return (env or settings.public_url).rstrip("/")


def build_line_code_payload(line: Line, node: Node) -> dict[str, Any]:
    return {
        "v": 1,
        "server": public_server_url(),
        "lineId": line.id,
        "tid": line.tid,
        "uuid": line.client_uuid,
        "nodeId": node.id,
        "nodeName": node.name,
    }


def refresh_line_code(line: Line, node: Node) -> str:
    return encode_line_code(build_line_code_payload(line, node))


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
        "proxyMode": device.proxy_mode or "gateway",
        "node": {
            "id": node.id,
            "name": node.name,
            "address": (node.public_ip or "").strip() or None,
            "port": int(reality.get("listenPort") or 443),
        },
        "vless": {
            "uuid": line.client_uuid,
            "flow": "xtls-rprx-vision",
            "serverName": (reality.get("serverNames") or ["www.microsoft.com"])[0],
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
