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


def load_proxy_mode() -> str:
    env_mode = env("GFC_PROXY_MODE", "").lower()
    file_mode = ""
    path = etc_dir() / "proxy-mode.json"
    if path.is_file():
        try:
            data = json.loads(path.read_text())
            file_mode = str(data.get("mode", "")).lower()
        except (OSError, json.JSONDecodeError):
            file_mode = ""
    if env_mode == "bypass":
        return "bypass"
    if file_mode in ("bypass", "transparent"):
        return file_mode
    if env_mode in ("gateway", "transparent"):
        return env_mode
    return "gateway"


def load_customer_hosts() -> list[str]:
    path = etc_dir() / "customer-hosts.json"
    if not path.is_file():
        return []
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return []
    raw = data.get("hosts") or []
    if isinstance(raw, str):
        raw = raw.replace(",", " ").split()
    out: list[str] = []
    seen: set[str] = set()
    for item in raw:
        token = str(item).strip()
        if not token or token in seen:
            continue
        try:
            if "/" in token:
                net = ipaddress.ip_network(token, strict=False)
            else:
                net = ipaddress.ip_network(token + "/32", strict=False)
        except ValueError:
            continue
        if net.version != 4:
            continue
        cidr = str(net) if net.prefixlen != 32 else str(net.network_address)
        if cidr not in seen:
            seen.add(cidr)
            out.append(cidr)
    return out


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
            lines.append(f"add element inet gfc TO_CN {{ {elems} }}")
    path.write_text("\n".join(lines) + "\n")
    path.chmod(0o644)
    return path


def normalize_mark(mark: str) -> str:
    raw = mark.strip().lower()
    if not raw.startswith("0x"):
        raw = "0x" + raw
    try:
        value = int(raw, 16)
    except ValueError:
        return "0x00002023"
    return f"0x{value:08x}"


def render_architecture(cfg: dict) -> str:
    """inet gfc per docs/NFT_ARCHITECTURE.md (kernel-split default)."""
    lan = cfg["lan"]
    wan = str(cfg.get("wan") or "").strip()
    tun = str(cfg.get("tun") or "gfctun").strip() or "gfctun"
    lan_cidr = cfg["lan_cidr"]
    mark = normalize_mark(cfg["mark"])
    ssh_port = cfg["ssh_port"]
    ext_const = fmt_ip_elements(cfg["ext_const_ips"])
    routing_mode = str(cfg.get("routing_mode", "split")).lower()
    proxy_mode = str(cfg.get("proxy_mode", "gateway")).lower()
    customer_hosts = cfg.get("customer_hosts") or []

    bypass_elems = fmt_bypass_elements(cfg.get("bypass_ips") or [])
    bypass_set_body = f"\n    elements = {{ {bypass_elems} }}" if bypass_elems else ""

    customer_set = ""
    if proxy_mode == "bypass":
        host_elems = fmt_ip_elements(list(customer_hosts))
        host_body = f"\n    elements = {{ {host_elems} }}" if host_elems else ""
        customer_set = f"""
  set customer_hosts {{
    type ipv4_addr
    flags interval{host_body}
  }}"""

    cn_lan = ""
    cn_wan = ""
    cn_output = ""
    if routing_mode != "global":
        cn_lan = f"""
    iifname "{lan}" ip daddr @TO_CN return"""
        if proxy_mode == "bypass" and wan:
            cn_wan = f"""
    iifname "{wan}" ip saddr @customer_hosts ip daddr @TO_CN return"""
        cn_output = """
    ip daddr @TO_CN return"""

    ct_head = ""
    ct_wan = ""
    route_head = ""
    route_wan = ""
    forward_customer = ""
    customer_output = ""
    if proxy_mode == "bypass":
        ct_head = f"""
    iifname "{tun}" return
    fib daddr type {{ local, broadcast, multicast }} return"""
        route_head = f"""
    iifname "{tun}" return
    fib daddr type {{ local, broadcast, multicast }} return"""
        if wan:
            ct_wan = f"""
    iifname "{wan}" ip saddr @customer_hosts ct state {{ established, related }} return
    iifname "{wan}" ip saddr @customer_hosts ct mark set {mark} accept"""
            route_wan = f"""
    iifname "{wan}" ip saddr @customer_hosts ip daddr {{ 10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }} return
    iifname "{wan}" ip saddr @customer_hosts ip daddr @customer_hosts return
    iifname "{wan}" ip saddr @customer_hosts udp dport {{ 53, 67, 68, 123 }} return
    iifname "{wan}" ip saddr @customer_hosts ip daddr @bypass_ip return
    # WAN: shared prerouting_user_overlay jumped above; system defaults follow
    iifname "{wan}" ip saddr @customer_hosts ip daddr @ext_const ct mark {mark} meta mark set ct mark return{cn_wan}
    iifname "{wan}" ip saddr @customer_hosts ct mark {mark} meta mark set ct mark"""
        forward_customer = """
    ct state new ip saddr @customer_hosts ct mark set meta mark"""
        customer_output = """
    ip daddr @customer_hosts return"""

    cn_load = cfg["cn_load_path"]
    cn_count = cfg["cn_count"]

    return f"""#!/usr/sbin/nft -f
# GFC client inet gfc — docs/NFT_ARCHITECTURE.md
# routing_mode={routing_mode}; proxy_mode={proxy_mode}; TO_CN: {cn_count} prefixes via {cn_load}
table inet gfc {{
  set TO_CN {{
    type ipv4_addr
    flags interval
  }}

  set TO_RFC1918 {{
    type ipv4_addr
    flags interval
    elements = {{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }}
  }}

  set bypass_ip {{
    type ipv4_addr
    flags interval{bypass_set_body}
  }}{customer_set}

  set ext {{
    type ipv4_addr
    size 262144
    timeout 2h
  }}

  set ext_const {{
    type ipv4_addr
    elements = {{ {ext_const} }}
  }}

  # User Overlay (docs/USER_POLICY_ROUTING.md §7) — filled by policy-routing apply
  chain prerouting_user_overlay {{
  }}

  chain output_user_overlay {{
  }}

  chain prerouting_mangle_ct {{
    type filter hook prerouting priority mangle; policy accept;{ct_head}
    iifname "{lan}" ct mark set {mark} accept{ct_wan}
  }}

  chain prerouting_mangle_route {{
    type filter hook prerouting priority filter; policy accept;{route_head}
    iifname "{lan}" ip daddr {{ 10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }} return
    iifname "{lan}" ip daddr {lan_cidr} return
    iifname "{lan}" udp dport {{ 53, 67, 68, 123 }} return
    iifname "{lan}" ip daddr @bypass_ip return
    # --- GFC_USER_OVERLAY_BEGIN (after bypass_ip / before system default) ---
    jump prerouting_user_overlay
    # --- GFC_USER_OVERLAY_END ---
    iifname "{lan}" ip daddr @ext_const ct mark {mark} meta mark set ct mark return{cn_lan}
    iifname "{lan}" ct mark {mark} meta mark set ct mark{route_wan}
  }}

  chain gfc_forward {{
    type filter hook forward priority filter; policy accept;
    ct state established,related accept
    ct state new ip saddr {lan_cidr} ct mark set meta mark{forward_customer}
    accept
  }}

  chain output_mangle_route {{
    type route hook output priority filter; policy accept;
    meta mark != 0x00000000 return
    tcp dport {ssh_port} return
    ip daddr @TO_RFC1918 return
    ip daddr 127.0.0.0/8 return{customer_output}{cn_output}
    ip daddr @bypass_ip counter return
    # --- GFC_USER_OVERLAY_OUTPUT_BEGIN (after bypass_ip / before catch-all mark) ---
    jump output_user_overlay
    # --- GFC_USER_OVERLAY_OUTPUT_END ---
    meta mark set {mark}
    ct mark set meta mark
  }}
}}
"""


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

  {bypass_set}

  set ext {{
    type ipv4_addr
    flags timeout
    timeout 7200s
    size 262144
  }}

  set ext_const {{
    type ipv4_addr
    elements = {{ {ext_const} }}
  }}

  chain mark_proxy {{
    meta mark set {mark}
    ct mark set meta mark
    accept
  }}

  chain classify_non_tcp {{
    meta mark set ct mark
    meta mark {mark} accept
    ip daddr {{ 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }} return
    ip daddr {lan_cidr} return
    udp dport {{ 53, 67, 68, 123 }} return{bypass_return}
    ip daddr @ext_const jump mark_proxy
    ip daddr @ext jump mark_proxy
    ip daddr != @cn_ip jump mark_proxy
    ct mark set meta mark
    accept
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
    meta mark != 0x00000000 accept
    oif lo return
    oifname "{tun}" return
    iifname "{tun}" return
    meta skuid {singbox_uid} return
    meta l4proto tcp tcp sport {ssh_port} return
    udp dport 123 return
    {wan_match}meta l4proto != tcp jump classify_non_tcp
  }}

  chain prerouting_nat {{
    type nat hook prerouting priority dstnat; policy accept;
    iifname "{lan}" meta l4proto tcp ip daddr != @cn_ip redirect to :{redirect_port}
    iifname "{lan}" meta l4proto tcp jump redirect_tcp
  }}

  chain output_nat {{
    type nat hook output priority dstnat; policy accept;
    meta mark != 0x00000000 accept
    oif lo return
    oifname "{tun}" return
    meta skuid {singbox_uid} return
    meta l4proto tcp tcp sport {ssh_port} return
    iifname "{wan}" meta l4proto tcp ip daddr != @cn_ip redirect to :{redirect_port}
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
        "ext_const_ips": env("GFC_EXT_CONST_IPS", "8.8.4.4,8.8.8.8,1.1.1.1,1.0.0.1").split(","),
        "bypass_ips": bypass_ips,
        "cn_count": len(cn_cidrs),
        "cn_load_path": str(cn_load),
    }
    cfg["routing_mode"] = load_routing_mode()
    cfg["proxy_mode"] = load_proxy_mode()
    cfg["customer_hosts"] = load_customer_hosts() if cfg["proxy_mode"] == "bypass" else []

    if scheme == "kernel-split":
        body = render_architecture(cfg)
    elif scheme == "byst-redirect":
        body = scheme_c(cfg)
    else:
        body = scheme_a(cfg)
    outfile.write_text(body)
    print(
        f"    nft policy scheme={scheme} mode={cfg['routing_mode']} proxy={cfg['proxy_mode']} cn={len(cn_cidrs)} "
        f"bypass={bypass_ips or 'none'} hosts={cfg['customer_hosts'] or 'none'} -> {outfile}"
    )
    print(f"    nft cn load -> {cn_load} ({(len(cn_cidrs) + BATCH_SIZE - 1) // BATCH_SIZE if cn_cidrs else 0} batches)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
