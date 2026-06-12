from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any

from .activation import is_line_activated
from .bootstrap import ensure_bootstrap_dataplane
from .dns_lists import ensure_default_lists
from .easymosdns_config import MOSDNS_CONFIG, mosdns_config_ok, render_mosdns_config_file
from .proxy_mode import apply_proxy_mode
from .routing_mode import read_routing_mode
from .singbox import singbox_config_ok, write_singbox_config
from .sysctl_util import ensure_network_tuning

GFC_ETC = Path(os.environ.get("GFC_ETC", "/etc/gfc-client"))
CONFIG_BUNDLE = Path(
    os.environ.get(
        "GFC_CONFIG_BUNDLE",
        "/opt/gfc-client/client-agent/state/dataplane/config_bundle.json",
    )
)


def _write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def _restart_unit(unit: str) -> str:
    if not Path("/bin/systemctl").exists():
        return f"{unit}: no systemd"
    r = subprocess.run(["systemctl", "restart", unit], capture_output=True, text=True)
    if r.returncode == 0:
        return f"{unit}: restarted"
    return f"{unit}: {r.stderr or r.stdout or 'failed'}"


def _detect_default_iface() -> str | None:
    try:
        r = subprocess.run(
            ["ip", "-4", "route", "show", "default"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        parts = (r.stdout or "").split()
        if "dev" in parts:
            return parts[parts.index("dev") + 1]
    except (OSError, ValueError):
        pass
    return None


def _load_payload(config_dir: Path) -> dict[str, Any]:
    bundle = config_dir / "config_bundle.json"
    if not bundle.is_file():
        bundle = CONFIG_BUNDLE
    if bundle.is_file():
        try:
            data = json.loads(bundle.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return data
        except (OSError, json.JSONDecodeError):
            pass
    return {}


def _payload_has_node(payload: dict[str, Any]) -> bool:
    return bool((payload.get("node") or {}).get("address"))


def apply_payload(
    payload: dict[str, Any],
    config_dir: Path,
    *,
    restart_services: bool = True,
) -> tuple[bool, str]:
    if not _payload_has_node(payload):
        return ensure_bootstrap_dataplane(try_download=False)

    config_dir.mkdir(parents=True, exist_ok=True)
    payload = dict(payload)
    payload["routingMode"] = payload.get("routingMode") or read_routing_mode()
    _write_json(config_dir / "config_bundle.json", payload)

    messages: list[str] = [f"sysctl: {ensure_network_tuning()}"]

    proxy_mode = (payload.get("proxyMode") or os.environ.get("GFC_PROXY_MODE") or "gateway").strip()
    lan_iface = (os.environ.get("GFC_LAN_IFACE") or "").strip() or None
    wan_iface = (os.environ.get("GFC_WAN_IFACE") or "").strip() or _detect_default_iface()

    ensure_default_lists()
    render_mosdns_config_file(try_download=False)
    ok_md, md_err = mosdns_config_ok(MOSDNS_CONFIG)
    if not ok_md:
        return False, f"mosdns check fail: {md_err}"
    messages.append("mosdns easymosdns ok")

    try:
        sb_path = write_singbox_config(payload)
    except ValueError as exc:
        return False, str(exc)

    ok_sb, sb_err = singbox_config_ok(sb_path)
    if not ok_sb:
        return False, f"sing-box check fail: {sb_err}"
    messages.append("sing-box active config ok")

    ok_pm, pm_msg = apply_proxy_mode(
        proxy_mode,
        lan_iface=lan_iface,
        wan_iface=wan_iface,
    )
    messages.append(f"proxy: {pm_msg}")
    if not ok_pm:
        return False, "; ".join(messages)

    Path("/var/lib/gfc-client").mkdir(parents=True, exist_ok=True)
    (GFC_ETC / "dataplane-mode.json").write_text(
        json.dumps({"mode": "active", "activated": True}, indent=2),
        encoding="utf-8",
    )
    if restart_services:
        messages.append(_restart_unit("gfc-mosdns.service"))
        messages.append(_restart_unit("gfc-client-sing-box.service"))
    else:
        messages.append("dataplane restart deferred")

    return True, "; ".join(messages)


def restart_dataplane_services() -> str:
    msgs = [
        _restart_unit("gfc-mosdns.service"),
        _restart_unit("gfc-client-sing-box.service"),
    ]
    return "; ".join(msgs)


def apply_dns_config(config_dir: Path | None = None) -> tuple[bool, str]:
    del config_dir
    return ensure_bootstrap_dataplane(try_download=False)


def reapply_local_config(config_dir: Path | None = None) -> tuple[bool, str]:
    cfg_dir = config_dir or CONFIG_BUNDLE.parent
    payload = _load_payload(cfg_dir)
    if not _payload_has_node(payload) or not is_line_activated():
        from .easymosdns_config import EASYMODNS_DIR

        need_fetch = not (EASYMODNS_DIR / "config.yaml").is_file() or not MOSDNS_CONFIG.is_file()
        return ensure_bootstrap_dataplane(try_download=need_fetch)
    payload["routingMode"] = read_routing_mode()
    return apply_payload(payload, cfg_dir)
