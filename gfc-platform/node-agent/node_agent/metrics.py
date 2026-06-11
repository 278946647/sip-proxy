from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any


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


def collect_metrics(
    server_url: str,
    client_reachable: bool,
    config_dir: Path | None = None,
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

    return {
        "control_plane_reachable": client_reachable,
        "services": services,
    }
