from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any

from .mosdns import render_mosdns_config
from .proxy_mode import apply_proxy_mode
from .singbox import singbox_config_ok, write_singbox_config
from .sysctl_util import ensure_network_tuning

GFC_ETC = Path(os.environ.get("GFC_ETC", "/etc/gfc-client"))
MOSDNS_CONFIG = GFC_ETC / "mosdns.yaml"
MOSDNS_DOMAIN_DIR = GFC_ETC / "mosdns"
DEFAULT_CN_DOMAINS = MOSDNS_DOMAIN_DIR / "cn-domains.txt"


def _write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def _write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def _ensure_cn_domain_list() -> None:
    if DEFAULT_CN_DOMAINS.is_file():
        return
    MOSDNS_DOMAIN_DIR.mkdir(parents=True, exist_ok=True)
    DEFAULT_CN_DOMAINS.write_text(
        "\n".join(
            [
                "baidu.com",
                "qq.com",
                "taobao.com",
                "alipay.com",
                "bilibili.com",
                "163.com",
                "126.com",
                "weixin.qq.com",
                "cn",
            ]
        )
        + "\n",
        encoding="utf-8",
    )


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


def apply_payload(payload: dict[str, Any], config_dir: Path) -> tuple[bool, str]:
    config_dir.mkdir(parents=True, exist_ok=True)
    _write_json(config_dir / "config_bundle.json", payload)

    messages: list[str] = [f"sysctl: {ensure_network_tuning()}"]

    proxy_mode = (payload.get("proxyMode") or os.environ.get("GFC_PROXY_MODE") or "gateway").strip()
    lan_iface = (os.environ.get("GFC_LAN_IFACE") or "").strip() or None
    wan_iface = (os.environ.get("GFC_WAN_IFACE") or "").strip() or _detect_default_iface()

    _ensure_cn_domain_list()
    _write_text(MOSDNS_CONFIG, render_mosdns_config(payload))
    messages.append("mosdns config written")

    try:
        sb_path = write_singbox_config(payload)
    except ValueError as exc:
        return False, str(exc)

    ok_sb, sb_err = singbox_config_ok(sb_path)
    if not ok_sb:
        return False, f"sing-box check fail: {sb_err}"
    messages.append("sing-box config ok")

    ok_pm, pm_msg = apply_proxy_mode(
        proxy_mode,
        lan_iface=lan_iface,
        wan_iface=wan_iface,
    )
    messages.append(f"proxy: {pm_msg}")
    if not ok_pm:
        return False, "; ".join(messages)

    Path("/var/lib/gfc-client").mkdir(parents=True, exist_ok=True)
    messages.append(_restart_unit("gfc-mosdns.service"))
    messages.append(_restart_unit("gfc-client-sing-box.service"))

    return True, "; ".join(messages)
