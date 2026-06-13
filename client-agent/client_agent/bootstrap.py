from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any

from .activation import is_line_activated
from .easymosdns_config import MOSDNS_CONFIG, mosdns_config_ok, render_mosdns_config_file
from .proxy_mode import apply_proxy_mode
from .rules_fetch import ensure_local_rules
from .singbox import singbox_config_ok, write_singbox_idle_config


def _restart_unit(unit: str) -> str:
    if not Path("/bin/systemctl").exists():
        return f"{unit}: no systemd"
    r = subprocess.run(["systemctl", "restart", unit], capture_output=True, text=True)
    if r.returncode == 0:
        return f"{unit}: restarted"
    return f"{unit}: {r.stderr or r.stdout or 'failed'}"


def _enable_start_unit(unit: str) -> str:
    subprocess.run(["systemctl", "enable", unit], capture_output=True, check=False)
    r = subprocess.run(["systemctl", "restart", unit], capture_output=True, text=True)
    if r.returncode == 0:
        return f"{unit}: active"
    return f"{unit}: {r.stderr or r.stdout or 'failed'}"


def ensure_bootstrap_dataplane(*, try_download: bool = True) -> tuple[bool, str]:
    """Idle dataplane: easymosdns mosdns + sing-box empty config (no TUN hijack)."""
    import os

    messages: list[str] = []

    _rules_ok, rules_msg = ensure_local_rules(try_download=try_download)
    if rules_msg:
        messages.append(f"meta-rules: {'; '.join(rules_msg)}")

    try:
        render_mosdns_config_file(try_download=try_download)
    except RuntimeError as exc:
        return False, f"easymosdns: {exc}"

    ok_md, md_err = mosdns_config_ok(MOSDNS_CONFIG)
    if not ok_md:
        return False, f"mosdns check fail: {md_err}"
    messages.append("mosdns easymosdns ok")

    sb_path = write_singbox_idle_config()
    ok_sb, sb_err = singbox_config_ok(sb_path)
    if not ok_sb:
        return False, f"sing-box idle check fail: {sb_err}"
    messages.append("sing-box idle ok")

    lan = os.environ.get("GFC_LAN_IFACE", "").strip() or None
    wan = os.environ.get("GFC_WAN_IFACE", "").strip() or None
    ok_pm, pm_msg = apply_proxy_mode("bypass", lan_iface=lan, wan_iface=wan)
    messages.append(f"proxy idle: {pm_msg}")

    for unit in ("gfc-mosdns.service", "gfc-client-sing-box.service"):
        messages.append(_restart_unit(unit))

    status_path = Path(os.environ.get("GFC_ETC", "/etc/gfc-client")) / "dataplane-mode.json"
    status_path.write_text(
        json.dumps({"mode": "idle", "activated": is_line_activated()}, indent=2),
        encoding="utf-8",
    )
    return True, "; ".join(messages)


def ensure_services_running() -> tuple[bool, str]:
    msgs = []
    for unit in (
        "gfc-mosdns.service",
        "gfc-client-sing-box.service",
        "gfc-client-web.service",
        "gfc-client-flash.service",
        "gfc-client-agent.service",
    ):
        msgs.append(_enable_start_unit(unit))
    return True, "; ".join(msgs)
