from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Any

GFC_ETC = Path("/etc/gfc-client")
NFTABLES_CONFIG = GFC_ETC / "gfc-client.nft"
TPROXY_PORT = 7895
TPROXY_MARK = 0x1


def _render_nft_transparent(lan_iface: str, tproxy_port: int = TPROXY_PORT) -> str:
    return f"""#!/usr/sbin/nft -f
table inet gfc_client {{
  chain prerouting {{
    type filter hook prerouting priority mangle; policy accept;
    iifname "{lan_iface}" ip daddr {{ 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4 }} return
    iifname "{lan_iface}" meta l4proto {{ tcp, udp }} meta mark set {TPROXY_MARK} tproxy ip to 127.0.0.1:{tproxy_port} accept
  }}
  chain output {{
    type route hook output priority mangle; policy accept;
    meta mark {TPROXY_MARK} meta mark set {TPROXY_MARK} accept
  }}
}}
"""


def _render_nft_gateway_masq(wan_iface: str) -> str:
    return f"""#!/usr/sbin/nft -f
table ip gfc_client_nat {{
  chain postrouting {{
    type nat hook postrouting priority srcnat; policy accept;
    oifname "{wan_iface}" masquerade
  }}
}}
"""


def ensure_tproxy_policy(tproxy_port: int = TPROXY_PORT) -> list[str]:
    msgs: list[str] = []
    subprocess.run(["ip", "rule", "add", "fwmark", str(TPROXY_MARK), "lookup", "100"], check=False)
    subprocess.run(
        ["ip", "route", "replace", "local", "0.0.0.0/0", "dev", "lo", "table", "100"],
        check=False,
    )
    msgs.append("tproxy policy route ok")
    return msgs


def nftables_active() -> bool:
    r = subprocess.run(
        ["nft", "list", "table", "inet", "gfc_client"],
        capture_output=True,
        text=True,
        check=False,
    )
    return r.returncode == 0


def apply_proxy_mode(
    mode: str,
    *,
    lan_iface: str | None,
    wan_iface: str | None,
    tproxy_port: int = TPROXY_PORT,
) -> tuple[bool, str]:
    mode = (mode or "gateway").strip().lower()
    messages: list[str] = [f"mode={mode}"]

    subprocess.run(
        ["nft", "delete", "table", "inet", "gfc_client"],
        capture_output=True,
        check=False,
    )
    subprocess.run(
        ["nft", "delete", "table", "ip", "gfc_client_nat"],
        capture_output=True,
        check=False,
    )

    if mode == "transparent":
        if not lan_iface:
            return False, "transparent mode requires GFC_LAN_IFACE"
        nft = _render_nft_transparent(lan_iface, tproxy_port)
        NFTABLES_CONFIG.write_text(nft, encoding="utf-8")
        ensure_tproxy_policy(tproxy_port)
        r = subprocess.run(["nft", "-f", str(NFTABLES_CONFIG)], capture_output=True, text=True)
        if r.returncode != 0:
            return False, f"nftables: {r.stderr or r.stdout}"
        messages.append(f"tproxy on {lan_iface}")
    elif mode == "gateway":
        if wan_iface:
            nat = _render_nft_gateway_masq(wan_iface)
            nat_path = GFC_ETC / "gfc-client-nat.nft"
            nat_path.write_text(nat, encoding="utf-8")
            r = subprocess.run(["nft", "-f", str(nat_path)], capture_output=True, text=True)
            if r.returncode == 0:
                messages.append(f"masquerade on {wan_iface}")
    elif mode == "bypass":
        messages.append("bypass: tun without auto_route; set GFC_BYPASS_CIDRS if needed")
    else:
        return False, f"unknown proxy mode: {mode}"

    return True, "; ".join(messages)
