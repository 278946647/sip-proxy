"""Forward-node nftables renderer — must match docs/NFT_ARCHITECTURE.md §13."""
from __future__ import annotations

TPROXY_MARK = "0x00000100"
LOCAL_EGRESS_MARK = "0x00000001"
RFC1918 = "10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/8"
OUTPUT_LOCAL = "10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/8"


def _fmt_bypass(cidrs: list[str]) -> str:
    parts: list[str] = []
    for raw in cidrs:
        c = raw.strip()
        if not c:
            continue
        parts.append(c if "/" in c else f"{c}/32")
    return ", ".join(parts)


def render_forward_nft(
    *,
    wan_iface: str,
    tproxy_iface: str,
    tproxy_port: int,
    bypass_cidrs: list[str] | None = None,
) -> str:
    elems = _fmt_bypass(bypass_cidrs or [])
    bypass_body = "    type ipv4_addr\n    flags interval"
    if elems:
        bypass_body += f"\n    elements = {{ {elems} }}"
    bypass_block = f"""
  set bypass_ip {{
{bypass_body}
  }}"""
    return f"""#!/usr/sbin/nft -f
# GFC forward node — see docs/NFT_ARCHITECTURE.md
table inet gfc {{{bypass_block}
  chain prerouting {{
    type filter hook prerouting priority mangle; policy accept;
    meta mark {TPROXY_MARK} return
    ip daddr {{ {RFC1918} }} return
    ip daddr @bypass_ip return
    iifname "{wan_iface}" return
    iifname "{tproxy_iface}" meta l4proto tcp meta mark set {TPROXY_MARK} tproxy ip to :{tproxy_port} accept
    iifname "{tproxy_iface}" meta l4proto udp meta mark set {TPROXY_MARK} tproxy ip to :{tproxy_port} accept
  }}

  chain output {{
    type route hook output priority mangle; policy accept;
    meta mark != 0x00000000 return
    tcp dport 212 return
    ip daddr {{ {OUTPUT_LOCAL} }} return
    ip daddr @bypass_ip return
    meta mark set {LOCAL_EGRESS_MARK}
    ct mark set meta mark
    oifname "{wan_iface}" return
  }}
}}
"""
