from __future__ import annotations

import json
import os
import socket
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .line_code import decode_line_code
from .sysctl_util import bbr_available, sysctl_get
from .version import AGENT_VERSION

GFC_ENV = Path(os.environ.get("GFC_ENV_FILE", "/etc/gfc-client/gfc.env"))
ACTIVATION_FILE = Path(
    os.environ.get("ACTIVATION_FILE", "/etc/gfc-client/activation.b32")
)
STATE_FILE = Path(
    os.environ.get(
        "STATE_FILE",
        "/opt/gfc-client/client-agent/state/client_state.json",
    )
)


def _mac_address() -> str | None:
    node = uuid.getnode()
    if (node >> 40) % 2:
        return None
    return ":".join(f"{(node >> shift) & 0xFF:02x}" for shift in range(40, -1, -8))


def _read_env_file() -> dict[str, str]:
    out: dict[str, str] = {}
    if not GFC_ENV.is_file():
        return out
    for line in GFC_ENV.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        out[key.strip()] = val.strip()
    return out


def _load_state() -> dict[str, Any] | None:
    if not STATE_FILE.is_file():
        return None
    try:
        data = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except (OSError, json.JSONDecodeError):
        return None


def _activation_summary() -> dict[str, Any]:
    result: dict[str, Any] = {
        "has_line_code": False,
        "line_tid": None,
        "line_id": None,
        "server_urls": [],
        "node_name": None,
        "valid": False,
        "error": None,
    }
    if not ACTIVATION_FILE.is_file():
        return result
    try:
        raw = ACTIVATION_FILE.read_text(encoding="utf-8").strip()
        if not raw:
            return result
        result["has_line_code"] = True
        payload = decode_line_code(raw)
        result["valid"] = True
        result["line_tid"] = payload.get("tid")
        result["line_id"] = payload.get("lineId")
        result["node_name"] = payload.get("nodeName")
        servers: list[str] = []
        for key in ("server", "serverFallback"):
            val = (payload.get(key) or "").strip()
            if val:
                servers.append(val)
        extra = payload.get("servers")
        if isinstance(extra, list):
            servers.extend(str(s).strip() for s in extra if str(s).strip())
        result["server_urls"] = list(dict.fromkeys(servers))
    except (OSError, ValueError) as exc:
        result["error"] = str(exc)
    return result


def list_network_interfaces() -> list[dict[str, Any]]:
    ifaces: list[dict[str, Any]] = []
    try:
        r = subprocess.run(
            ["ip", "-j", "addr", "show"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        if r.returncode == 0 and r.stdout.strip():
            for item in json.loads(r.stdout):
                name = item.get("ifname", "")
                if name == "lo":
                    continue
                addrs = []
                for addr in item.get("addr_info") or []:
                    if addr.get("family") == "inet":
                        addrs.append(
                            {
                                "address": addr.get("local"),
                                "prefix": addr.get("prefixlen"),
                            }
                        )
                ifaces.append(
                    {
                        "name": name,
                        "state": item.get("operstate", "unknown"),
                        "addresses": addrs,
                        "mac": item.get("address"),
                    }
                )
            return ifaces
    except (OSError, json.JSONDecodeError, subprocess.TimeoutExpired):
        pass

    try:
        with open("/proc/net/dev", "r", encoding="utf-8") as f:
            for line in f.readlines()[2:]:
                if ":" not in line:
                    continue
                name = line.split(":", 1)[0].strip()
                if name and name != "lo":
                    ifaces.append({"name": name, "state": "unknown", "addresses": []})
    except OSError:
        pass
    return ifaces


def collect_device_info(control_plane_url: str | None = None) -> dict[str, Any]:
    env = _read_env_file()
    state = _load_state()
    activation = _activation_summary()
    hostname = socket.gethostname()

    return {
        "agent_version": AGENT_VERSION,
        "hostname": hostname,
        "device_name": env.get("DEVICE_NAME") or hostname,
        "mac": _mac_address(),
        "activated": state is not None,
        "device_id": state.get("device_id") if state else None,
        "line_tid": state.get("tid") if state else activation.get("line_tid"),
        "line_id": state.get("line_id") if state else activation.get("line_id"),
        "applied_version": state.get("applied_version") if state else None,
        "proxy_mode": env.get("GFC_PROXY_MODE", "gateway"),
        "lan_iface": env.get("GFC_LAN_IFACE") or None,
        "wan_iface": env.get("GFC_WAN_IFACE") or None,
        "control_plane_url": control_plane_url or env.get("SERVER_URL") or None,
        "activation": activation,
        "network": {
            "ip_forward": sysctl_get("net.ipv4.ip_forward") == "1",
            "tcp_congestion_control": sysctl_get("net.ipv4.tcp_congestion_control"),
            "bbr_available": bbr_available(),
        },
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }


def read_settings() -> dict[str, Any]:
    env = _read_env_file()
    return {
        "device_name": env.get("DEVICE_NAME") or socket.gethostname(),
        "proxy_mode": env.get("GFC_PROXY_MODE", "gateway"),
        "lan_iface": env.get("GFC_LAN_IFACE") or "",
        "wan_iface": env.get("GFC_WAN_IFACE") or "",
        "server_url": env.get("SERVER_URL") or "",
        "server_url_fallback": env.get("SERVER_URL_FALLBACK") or "",
        "poll_seconds": int(env.get("POLL_SECONDS", "10") or "10"),
        "reverse_ssh_port": env.get("REVERSE_SSH_PORT") or "",
    }
