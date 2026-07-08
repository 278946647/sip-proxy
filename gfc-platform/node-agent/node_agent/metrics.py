from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

_last_iface_counters: dict[str, tuple[int, int]] = {}


def _systemd_active(unit: str) -> dict[str, Any]:
    try:
        r = subprocess.run(
            ["systemctl", "is-active", unit],
            capture_output=True,
            text=True,
            timeout=5,
        )
        active = r.stdout.strip() == "active"
        return {
            "active": active,
            "status": r.stdout.strip(),
            "message": None if active else (r.stderr.strip() or r.stdout.strip()),
        }
    except Exception as e:  # noqa: BLE001
        return {"active": False, "status": "unknown", "message": str(e)}


def _binary_exists(name: str) -> bool:
    return shutil.which(name) is not None


def _connect_mode(config_dir: Path | None) -> str:
    candidates: list[Path] = []
    if config_dir:
        candidates.append(config_dir / "config_bundle.json")
    gfc_root = os.environ.get("GFC_ROOT", "/opt/gfc-node").strip()
    if gfc_root:
        candidates.append(Path(gfc_root) / "node-agent/state/dataplane/config_bundle.json")
    for path in candidates:
        if not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            return (data.get("connectMode") or "ethernet").strip() or "ethernet"
        except (OSError, json.JSONDecodeError, TypeError, ValueError):
            continue
    return "ethernet"


def _read_iface_bytes(iface: str) -> tuple[int, int] | None:
    base = Path("/sys/class/net") / iface / "statistics"
    try:
        rx = int((base / "rx_bytes").read_text(encoding="utf-8").strip())
        tx = int((base / "tx_bytes").read_text(encoding="utf-8").strip())
        return rx, tx
    except (OSError, ValueError):
        return None


def _default_route_iface() -> str | None:
    try:
        with open("/proc/net/route", "r", encoding="utf-8") as f:
            for line in f.readlines()[1:]:
                parts = line.split()
                if len(parts) >= 11 and parts[1] == "00000000":
                    name = parts[0].strip()
                    if name and name != "lo":
                        return name
    except OSError:
        return None
    return None


def _resolve_traffic_iface(config_dir: Path | None) -> str | None:
    for key in ("GFC_TRAFFIC_IFACE", "GFC_WAN_IFACE", "GFC_TPROXY_IFACE"):
        val = os.environ.get(key, "").strip()
        if val:
            return val
    if config_dir:
        bundle = config_dir / "config_bundle.json"
        if bundle.is_file():
            try:
                data = json.loads(bundle.read_text(encoding="utf-8"))
                for field in ("tproxyIface", "wanIface"):
                    val = str(data.get(field) or "").strip()
                    if val:
                        return val
            except (OSError, json.JSONDecodeError, TypeError, ValueError):
                pass
    return _default_route_iface()


def sample_network_traffic(config_dir: Path | None, window_seconds: int) -> dict[str, Any] | None:
    iface = _resolve_traffic_iface(config_dir)
    if not iface:
        return None
    counters = _read_iface_bytes(iface)
    if counters is None:
        return None
    rx, tx = counters
    out: dict[str, Any] = {
        "iface": iface,
        "window_seconds": max(1, window_seconds),
        "bytes_in": 0,
        "bytes_out": 0,
        "cumulative_rx": rx,
        "cumulative_tx": tx,
    }
    prev = _last_iface_counters.get(iface)
    if prev is not None:
        prev_rx, prev_tx = prev
        if rx >= prev_rx:
            out["bytes_in"] = rx - prev_rx
        if tx >= prev_tx:
            out["bytes_out"] = tx - prev_tx
    _last_iface_counters[iface] = (rx, tx)
    return out


def collect_metrics(
    server_url: str,
    client_reachable: bool,
    config_dir: Path | None = None,
    poll_seconds: int = 10,
) -> dict[str, Any]:
    services: dict[str, Any] = {
        "gfc-node-agent": {"active": True, "status": "running", "message": "self"},
        "sing-box": _systemd_active("gfc-sing-box.service"),
    }
    if _connect_mode(config_dir) == "openvpn":
        services["openvpn-backbone"] = _systemd_active("openvpn@gfc-backbone.service")
    if not _binary_exists("sing-box"):
        services["sing-box"] = {
            "active": False,
            "status": "missing_binary",
            "message": "sing-box not installed",
        }

    out: dict[str, Any] = {
        "control_plane_reachable": client_reachable,
        "services": services,
    }
    net = sample_network_traffic(config_dir, poll_seconds)
    if net is not None:
        out["network_traffic"] = net
    return out
