from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any

from .env_sync import sync_bootstrap_token
from .nft_render import render_forward_nft
from .routes import (
    apply_egress_snat,
    apply_static_routes,
    ensure_local_egress_policy,
    ensure_tproxy_policy,
    resolve_snat_iface,
)
from .singbox import render_singbox_config, singbox_config_ok
from .socks_health import evaluate_socks_dns_health, format_dns_health_summary
from .sysctl_util import ensure_network_tuning
from .vpn import apply_openvpn, disable_openvpn

GFC_ETC = Path(os.environ.get("GFC_ETC", "/etc/gfc-node"))
SINGBOX_CONFIG = GFC_ETC / "sing-box.json"
NFTABLES_CONFIG = GFC_ETC / "gfc.nft"


def _write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def nftables_tproxy_active() -> bool:
    r = subprocess.run(
        ["nft", "list", "table", "inet", "gfc"],
        capture_output=True,
        text=True,
        check=False,
    )
    return r.returncode == 0 and "tproxy" in (r.stdout or "")


def _render_nftables(
    tproxy_port: int,
    tproxy_iface: str | None,
    wan_iface: str | None,
    bypass_cidrs: list[str] | None,
) -> str:
    if not tproxy_iface or not wan_iface:
        return ""
    return render_forward_nft(
        wan_iface=wan_iface,
        tproxy_iface=tproxy_iface,
        tproxy_port=tproxy_port,
        bypass_cidrs=bypass_cidrs,
    )


def apply_payload(payload: dict[str, Any], config_dir: Path) -> tuple[bool, str]:
    config_dir.mkdir(parents=True, exist_ok=True)
    bundle_path = config_dir / "config_bundle.json"
    _write_json(bundle_path, payload)

    messages: list[str] = [f"sysctl: {ensure_network_tuning()}"]

    connect_mode = payload.get("connectMode") or "ethernet"
    if connect_mode == "openvpn":
        ok, msg = apply_openvpn(payload.get("vpn"))
        messages.append(f"vpn: {msg}")
        if not ok:
            return False, "; ".join(messages)
    else:
        ok, msg = disable_openvpn()
        messages.append(f"vpn: {msg}")

    static_routes = payload.get("staticRoutes") or []
    ok_r, msg_r = apply_static_routes(static_routes)
    messages.append(f"routes: {msg_r}")
    if not ok_r and static_routes:
        return False, "; ".join(messages)

    dataplane = payload.get("dataplane") or {}
    client_ingress = payload.get("clientIngress") or {}
    socks_dns_ok = evaluate_socks_dns_health(payload, config_dir)
    sing_cfg = render_singbox_config(
        dataplane,
        client_ingress=client_ingress,
        socks_dns_ok=socks_dns_ok,
    )
    messages.append(format_dns_health_summary(socks_dns_ok))
    _write_json(SINGBOX_CONFIG, sing_cfg)
    ok_sb, sb_err = singbox_config_ok(SINGBOX_CONFIG)
    if not ok_sb:
        messages.append(f"sing-box check fail: {sb_err}")
        return False, "; ".join(messages)
    messages.append("sing-box config ok")

    tproxy_port = int(dataplane.get("tproxyPort") or 12345)
    tproxy_iface = (payload.get("tproxyIface") or "").strip() or None
    if not tproxy_iface:
        tproxy_iface = os.environ.get("GFC_TPROXY_IFACE", "").strip() or None
    bypass_cidrs = dataplane.get("bypassCidrs") or []
    if not isinstance(bypass_cidrs, list):
        bypass_cidrs = []

    snat_iface = resolve_snat_iface()
    ok_snat, msg_snat = apply_egress_snat(snat_iface)
    messages.append(f"snat: {msg_snat}")
    if not ok_snat:
        return False, "; ".join(messages)

    if tproxy_iface and snat_iface:
        messages.extend(ensure_tproxy_policy(tproxy_port))
        messages.extend(ensure_local_egress_policy(snat_iface))

    drift = sync_bootstrap_token(payload.get("bootstrapToken"))
    if drift:
        messages.append(drift)
    nft = _render_nftables(tproxy_port, tproxy_iface, snat_iface, bypass_cidrs)
    if nft:
        NFTABLES_CONFIG.write_text(nft, encoding="utf-8")
        subprocess.run(
            ["nft", "delete", "table", "inet", "gfc"],
            capture_output=True,
            text=True,
        )
        r = subprocess.run(["nft", "-f", str(NFTABLES_CONFIG)], capture_output=True, text=True)
        if r.returncode != 0:
            messages.append(f"nftables warn: {r.stderr or r.stdout}")
        else:
            messages.append("nftables applied")

    if Path("/bin/systemctl").exists():
        r = subprocess.run(
            ["systemctl", "restart", "gfc-sing-box.service"],
            capture_output=True,
            text=True,
        )
        if r.returncode == 0:
            messages.append("sing-box restarted")
        else:
            messages.append(f"sing-box skip: {r.stderr or 'not installed'}")
    else:
        messages.append("sing-box config written (no systemd)")

    return True, "; ".join(messages)
