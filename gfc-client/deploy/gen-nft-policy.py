#!/usr/bin/env python3
"""Generate gfc_client_mangle nftables config (scheme A or B).

CN IP set: empty set in main conf + batched `add element` in nftables-cn-ip-load.nft
(Ubuntu 22.04 nft 1.0.x does not support elements = { include "plain-cidr-file" }).

Plain CIDR list kept at nftables-cn-ip.set for audit only.
Bypass (relay node + CP): inline elements (small).
"""
from __future__ import annotations

import ipaddress
import json
import os
import socket
import sys
from pathlib import Path
from urllib.parse import urlparse

BATCH_SIZE = 400


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def etc_dir() -> Path:
    return Path(env("GFC_ETC", "/etc/gfc-client"))


def cn_audit_path() -> Path:
    return etc_dir() / "nftables-cn-ip.set"


def cn_load_path() -> Path:
    return etc_dir() / "nftables-cn-ip-load.nft"


def load_routing_mode() -> str:
    path = etc_dir() / "routing-mode.json"
    if not path.is_file():
        return "split"
    try:
        data = json.loads(path.read_text())
        return str(data.get("mode", "split")).lower()
    except (OSError, json.JSONDecodeError):
        return "split"


def load_cn_cidrs() -> list[str]:
    candidates = [
        etc_dir() / "mosdns/easymosdns/rules/china_ip_list.txt",
        Path(env("GFC_ROOT", "/opt/gfc-client"))
        / "share/easymosdns/rules/china_ip_list.txt",
    ]
    out: list[str] = []
    seen: set[str] = set()
    for path in candidates:
        if not path.is_file():
            continue
        for raw in path.read_text().splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            try:
                net = ipaddress.ip_network(line, strict=False)
            except ValueError:
                continue
            if net.version != 4:
                continue
            cidr = str(net)
            if cidr not in seen:
                seen.add(cidr)
                out.append(cidr)
        if out:
            break
    return out


def resolve_bypass_ips() -> list[str]:
    """Relay node + control plane — must bypass TUN for VLESS handshake."""
    seen: set[str] = set()
    out: list[str] = []

    def add_ip(ip: str) -> None:
        ip = ip.strip()
        if not ip or ip in seen:
            return
        seen.add(ip)
        out.append(ip)

    def add_host(host: str) -> None:
        host = (host or "").strip()
        if not host:
            return
        if host.startswith("["):
            host = host.strip("[]")
        try:
            for info in socket.getaddrinfo(host, None, socket.AF_INET):
                add_ip(info[4][0])
        except OSError:
            pass

    for raw in env("GFC_POLICY_BYPASS_IPS", "").split(","):
        token = raw.strip()
        if not token:
            continue
        if token.replace(".", "").isdigit() or "/" in token:
            add_ip(token.split("/")[0])
        else:
            add_host(token)

    bundle = Path("/var/lib/gfc-client/state/config_bundle.json")
    if bundle.is_file():
        try:
            data = json.loads(bundle.read_text())
            payload = data.get("payload") if isinstance(data.get("payload"), dict) else data
        except (OSError, json.JSONDecodeError):
            payload = {}
        node = payload.get("node") or {}
        add_host(str(node.get("address") or ""))
        for srv in payload.get("controlPlaneServers") or []:
            s = str(srv).strip()
            if "://" in s:
                add_host(urlparse(s).hostname or "")
            else:
                add_host(s)

    for key in ("GFC_NODE_BYPASS", "GFC_CP_BYPASS", "SERVER_URL", "SERVER_URL_FALLBACK"):
        raw = env(key)
        if not raw:
            continue
        if "://" in raw:
            add_host(urlparse(raw).hostname or "")
        else:
            add_host(raw)
    return out


def fmt_bypass_elements(ips: list[str]) -> str:
    parts: list[str] = []
    for ip in ips:
        parts.append(ip if "/" in ip else f"{ip}/32")
    return ", ".join(parts)


def fmt_ip_elements(ips: list[str]) -> str:
    out: list[str] = []
    seen: set[str] = set()
    for raw in ips:
        ip = raw.strip()
        if not ip or ip in seen:
            continue
        try:
            ipaddress.ip_network(ip, strict=False)
        except ValueError:
            continue
        seen.add(ip)
        out.append(ip)
    return ", ".join(out)


def write_cn_audit_file(cidrs: list[str]) -> None:
    path = cn_audit_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(("\n".join(cidrs) + "\n") if cidrs else "# empty\n")
    path.chmod(0o644)


def write_cn_load_nft(cidrs: list[str]) -> Path:
    """Batch add element — compatible with nft 1.0.x on Ubuntu 22.04."""
    path = cn_load_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["#!/usr/sbin/nft -f", "# Auto-generated CN IP set loader"]
    if not cidrs:
        lines.append("# (no CN prefixes — china_ip_list.txt missing)")
    else:
        for i in range(0, len(cidrs), BATCH_SIZE):
            batch = cidrs[i : i + BATCH_SIZE]
            elems = ", ".join(batch)
            lines.append(f"add element inet gfc_client_mangle cn_ip {{ {elems} }}")
    path.write_text("\n".join(lines) + "\n")
    path.chmod(0o644)
    return path


def scheme_a(cfg: dict) -> str:
    lan = cfg["lan"]
    lan_cidr = cfg["lan_cidr"]
    mark = cfg["mark"]
    tun = cfg["tun"]
    mosdns_uid = cfg["mosdns_uid"]
    singbox_uid = cfg["singbox_uid"]
    ssh_port = cfg["ssh_port"]
    bypass_set = ""
    bypass_chain = ""
    if cfg["bypass_ips"]:
        bypass_set = f"""
  set bypass_ip {{
    type ipv4_addr
    flags interval
    elements = {{ {fmt_bypass_elements(cfg["bypass_ips"])} }}
  }}"""
        bypass_chain = """
    ip daddr @bypass_ip return"""
    return f"""#!/usr/sbin/nft -f
# Scheme A (tun-all): split inside sing-box.
table inet gfc_client_mangle {{{bypass_set}
  chain prerouting {{
    type filter hook prerouting priority 200; policy accept;
    iifname "{lan}" ip daddr != {lan_cidr} tcp dport != {{ 53, 67, 68 }} meta mark set {mark}
    iifname "{lan}" ip daddr != {lan_cidr} udp dport != {{ 53, 67, 68 }} meta mark set {mark}
  }}
  chain output {{
    type route hook output priority 200; policy accept;
    meta mark {mark} return
    oifname "{tun}" return
    iifname "{tun}" return
    oif lo return
    ip daddr {{ 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }} return
    meta l4proto tcp tcp sport {ssh_port} return
    tcp dport {{ 53, 67, 68 }} return
    udp dport {{ 53, 67, 68 }} return{bypass_chain}
    meta skuid {singbox_uid} return
    meta skuid {mosdns_uid} ip daddr {{ 1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4 }} meta mark set {mark}
    meta skuid {mosdns_uid} tcp dport 443 meta mark set {mark}
    meta mark set {mark}
  }}
}}
"""


def scheme_b(cfg: dict) -> str:
    lan = cfg["lan"]
    lan_cidr = cfg["lan_cidr"]
    mark = cfg["mark"]
    tun = cfg["tun"]
    mosdns_uid = cfg["mosdns_uid"]
    singbox_uid = cfg["singbox_uid"]
    ssh_port = cfg["ssh_port"]
    cn_count = cfg["cn_count"]
    cn_load = cfg["cn_load_path"]
    routing_mode = cfg["routing_mode"]

    bypass_set = ""
    bypass_chain = ""
    if cfg["bypass_ips"]:
        bypass_set = f"""
  set bypass_ip {{
    type ipv4_addr
    flags interval
    elements = {{ {fmt_bypass_elements(cfg["bypass_ips"])} }}
  }}"""
        bypass_chain = """
    ip daddr @bypass_ip return"""

    cn_rule = ""
    if routing_mode != "global":
        cn_rule = """
    ip daddr @cn_ip return"""

    return f"""#!/usr/sbin/nft -f
# Scheme B (kernel-split, rollback-tag): CN → direct WAN; non-CN → mark {mark} → gfctun → VLESS.
# CN: {cn_count} prefixes via {cn_load}
table inet gfc_client_mangle {{
  set cn_ip {{
    type ipv4_addr
    flags interval
  }}{bypass_set}

  chain classify {{
    meta mark {mark} return
    ct mark != 0x00000000 meta mark set ct mark return
    ip daddr {{ 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }} return
    ip daddr {lan_cidr} return
    tcp dport {{ 53, 67, 68 }} return
    udp dport {{ 53, 67, 68 }} return{bypass_chain}{cn_rule}
    meta mark set {mark}
    ct mark set meta mark
  }}

  chain prerouting {{
    type filter hook prerouting priority 200; policy accept;
    iifname "{lan}" ip daddr != {lan_cidr} jump classify
  }}

  chain output {{
    type route hook output priority 200; policy accept;
    oif lo return
    oifname "{tun}" return
    iifname "{tun}" return
    meta skuid {singbox_uid} return
    meta l4proto tcp tcp sport {ssh_port} return
    meta skuid {mosdns_uid} ip daddr {{ 1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4 }} meta mark set {mark}
    meta skuid {mosdns_uid} tcp dport 443 meta mark set {mark}
    jump classify
  }}
}}
"""


def scheme_c(cfg: dict) -> str:
    lan = cfg["lan"]
    lan_cidr = cfg["lan_cidr"]
    wan = cfg["wan"]
    mark = cfg["mark"]
    tun = cfg["tun"]
    mosdns_uid = cfg["mosdns_uid"]
    singbox_uid = cfg["singbox_uid"]
    ssh_port = cfg["ssh_port"]
    cn_count = cfg["cn_count"]
    cn_load = cfg["cn_load_path"]
    redirect_port = cfg["redirect_port"]
    ext_const = fmt_ip_elements(cfg["ext_const_ips"])

    wan_match = f'oifname "{wan}" ' if wan else ""
    bypass_set = ""
    bypass_return = ""
    if cfg["bypass_ips"]:
        bypass_set = f"""
  set bypass_ip {{
    type ipv4_addr
    flags interval
    elements = {{ {fmt_bypass_elements(cfg["bypass_ips"])} }}
  }}"""
        bypass_return = """
    ip daddr @bypass_ip return"""

    return f"""#!/usr/sbin/nft -f
# Scheme C (byst-redirect): TCP → sing-box redirect :{redirect_port}; non-TCP non-CN → mark {mark} → {tun}.
# Rollback: set GFC_ROUTING_SCHEME=kernel-split and rerun apply-network.sh.
# CN: {cn_count} prefixes via {cn_load}
table inet gfc_client_mangle {{
  set cn_ip {{
    type ipv4_addr
    flags interval
  }}

  set ext {{
    type ipv4_addr
    flags timeout
    timeout 7200s
    size 262144
  }}

  set ext_const {{
    type ipv4_addr
    elements = {{ {ext_const} }}
  }}{bypass_set}

  chain mark_proxy {{
    meta mark set {mark}
    ct mark set meta mark
    accept
  }}

  chain classify_non_tcp {{
    ct mark != 0x00000000 meta mark set ct mark return
    meta mark {mark} return
    ip daddr {{ 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }} return
    ip daddr {lan_cidr} return
    udp dport {{ 53, 67, 68, 123 }} return{bypass_return}
    ip daddr @ext_const jump mark_proxy
    ip daddr != @cn_ip jump mark_proxy
    ip daddr @ext jump mark_proxy
  }}

  chain redirect_tcp {{
    ip daddr {{ 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }} return
    ip daddr {lan_cidr} return{bypass_return}
    meta l4proto tcp ip daddr @ext redirect to :{redirect_port}
    meta l4proto tcp ip daddr @ext_const redirect to :{redirect_port}
    meta l4proto tcp ip daddr != @cn_ip redirect to :{redirect_port}
  }}

  chain prerouting_mangle {{
    type filter hook prerouting priority mangle; policy accept;
    iifname "{lan}" meta l4proto != tcp jump classify_non_tcp
  }}

  chain output_mangle {{
    type route hook output priority mangle; policy accept;
    meta mark != 0x00000000 return
    oif lo return
    oifname "{tun}" return
    iifname "{tun}" return
    meta skuid {singbox_uid} return
    meta l4proto tcp tcp sport {ssh_port} return
    {wan_match}meta skuid {mosdns_uid} udp dport 123 return
    {wan_match}meta l4proto != tcp jump classify_non_tcp
  }}

  chain prerouting_nat {{
    type nat hook prerouting priority dstnat; policy accept;
    iifname "{lan}" meta l4proto tcp jump redirect_tcp
  }}

  chain output_nat {{
    type nat hook output priority dstnat; policy accept;
    meta mark != 0x00000000 return
    oif lo return
    oifname "{tun}" return
    meta skuid {singbox_uid} return
    meta l4proto tcp tcp sport {ssh_port} return
    {wan_match}meta l4proto tcp jump redirect_tcp
  }}
}}
"""


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: gen-nft-policy.py <outfile>", file=sys.stderr)
        return 2
    outfile = Path(sys.argv[1])
    scheme = env("GFC_ROUTING_SCHEME", "kernel-split").lower()
    cn_cidrs = load_cn_cidrs()
    bypass_ips = resolve_bypass_ips()

    if scheme in ("kernel-split", "byst-redirect") and not cn_cidrs:
        print("WARN: china_ip_list.txt missing — CN split needs CN IP list", file=sys.stderr)

    write_cn_audit_file(cn_cidrs)
    cn_load = write_cn_load_nft(cn_cidrs)

    cfg = {
        "lan": env("LAN") or env("GFC_LAN_IFACE") or env("GFC_BRIDGE_NAME", "bridge_lan"),
        "lan_cidr": env("LAN_CIDR")
        or env("GFC_LAN_CIDR")
        or env("GFC_LAN_NETWORK", "192.168.68.0/24"),
        "mark": env("GFC_POLICY_MARK", "0x2023"),
        "tun": env("GFC_TUN_INTERFACE", "gfctun"),
        "wan": env("WAN") or env("GFC_WAN_IFACE"),
        "mosdns_uid": env("GFC_MOSDNS_UID", "65353"),
        "singbox_uid": env("GFC_SINGBOX_UID", "65354"),
        "ssh_port": env("GFC_SSH_PORT", "212"),
        "redirect_port": env("GFC_REDIRECT_PORT", "11800"),
        "ext_const_ips": env("GFC_EXT_CONST_IPS", "100.100.100.1,8.8.8.8,8.8.4.4").split(","),
        "bypass_ips": bypass_ips,
        "cn_count": len(cn_cidrs),
        "cn_load_path": str(cn_load),
    }
    cfg["routing_mode"] = load_routing_mode()

    if scheme == "kernel-split":
        body = scheme_b(cfg)
    elif scheme == "byst-redirect":
        body = scheme_c(cfg)
    else:
        body = scheme_a(cfg)
    outfile.write_text(body)
    print(
        f"    nft policy scheme={scheme} cn={len(cn_cidrs)} bypass={bypass_ips or 'none'} -> {outfile}"
    )
    print(f"    nft cn load -> {cn_load} ({(len(cn_cidrs) + BATCH_SIZE - 1) // BATCH_SIZE if cn_cidrs else 0} batches)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
