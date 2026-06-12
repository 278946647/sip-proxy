from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any

GFC_ETC = Path(os.environ.get("GFC_ETC", "/etc/gfc-client"))
GFC_ENV = Path(os.environ.get("GFC_ENV_FILE", "/etc/gfc-client/gfc.env"))
NETPLAN_FILE = Path("/etc/netplan/99-gfc-client.yaml")
DNSMASQ_FILE = Path("/etc/dnsmasq.d/gfc-client.conf")
NFT_BOOT = GFC_ETC / "gfc-boot.nft"

LAN_ADDRESS = os.environ.get("GFC_LAN_ADDRESS", "192.168.68.1")
LAN_PREFIX = int(os.environ.get("GFC_LAN_PREFIX", "24"))
LAN_NETWORK = os.environ.get("GFC_LAN_NETWORK", "192.168.68.0")
LAN_NETMASK = os.environ.get("GFC_LAN_NETMASK", "255.255.255.0")
DHCP_START = os.environ.get("GFC_DHCP_START", "192.168.68.100")
DHCP_END = os.environ.get("GFC_DHCP_END", "192.168.68.250")
MOSDNS_PORT = int(os.environ.get("GFC_MOSDNS_PORT", "5335"))

_SKIP_IFACE_RE = re.compile(
    r"^(lo|docker\d*|veth.*|br-.*|virbr\d*|tailscale\d*|wg\d*|tun\d*|gfc\d*)$"
)


def _run(cmd: list[str], *, check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=60, check=check)


def list_physical_interfaces() -> list[str]:
    net = Path("/sys/class/net")
    if not net.is_dir():
        return []
    names: list[str] = []
    for p in net.iterdir():
        name = p.name
        if _SKIP_IFACE_RE.match(name):
            continue
        if (p / "device").exists() or name.startswith(("eth", "en", "eno", "ens", "enp")):
            names.append(name)

    def sort_key(n: str) -> tuple[int, str]:
        m = re.search(r"(\d+)$", n)
        return (int(m.group(1)) if m else 0, n)

    return sorted(names, key=sort_key)


def detect_wan_lan(
    wan: str | None = None,
    lan: str | None = None,
) -> tuple[str | None, str | None, list[str]]:
    ifaces = list_physical_interfaces()
    if not ifaces:
        return wan, lan, ifaces

    wan_iface = (wan or os.environ.get("GFC_WAN_IFACE") or "").strip() or ifaces[0]
    remaining = [i for i in ifaces if i != wan_iface]
    lan_iface = (lan or os.environ.get("GFC_LAN_IFACE") or "").strip()
    if not lan_iface and remaining:
        lan_iface = remaining[0]
    return wan_iface, lan_iface or None, ifaces


def _read_env_lines() -> list[str]:
    if GFC_ENV.is_file():
        return GFC_ENV.read_text(encoding="utf-8").splitlines()
    return []


def _write_env_value(key: str, value: str) -> None:
    lines = _read_env_lines()
    prefix = f"{key}="
    out: list[str] = []
    replaced = False
    for line in lines:
        if line.startswith(prefix):
            out.append(f"{key}={value}")
            replaced = True
        else:
            out.append(line)
    if not replaced:
        out.append(f"{key}={value}")
    GFC_ENV.parent.mkdir(parents=True, exist_ok=True)
    GFC_ENV.write_text("\n".join(out) + "\n", encoding="utf-8")
    os.chmod(GFC_ENV, 0o600)


def render_netplan(wan: str, lan: str | None) -> str:
    lan_block = ""
    if lan:
        lan_block = f"""
    {lan}:
      dhcp4: false
      addresses:
        - {LAN_ADDRESS}/{LAN_PREFIX}
      optional: true"""
    return f"""# GFC client box — OpenWrt-style WAN/LAN (managed by gfc-client-agent)
network:
  version: 2
  renderer: networkd
  ethernets:
    {wan}:
      dhcp4: true
      optional: true{lan_block}
"""


def render_dnsmasq(lan: str) -> str:
    return f"""# GFC client LAN DHCP + DNS forward to mosdns
interface={lan}
bind-interfaces
except-interface=lo
listen-address={LAN_ADDRESS}
dhcp-range={DHCP_START},{DHCP_END},{LAN_NETMASK},12h
dhcp-option=option:router,{LAN_ADDRESS}
dhcp-option=option:dns-server,{LAN_ADDRESS}
server=127.0.0.1#{MOSDNS_PORT}
no-resolv
cache-size=1000
"""


def render_boot_nft(wan: str | None, lan: str | None) -> str:
    masq = ""
    if wan:
        masq = f"""
table ip gfc_client_nat {{
  chain postrouting {{
    type nat hook postrouting priority srcnat; policy accept;
    oifname "{wan}" masquerade
  }}
}}"""
    forward = ""
    if wan and lan:
        forward = f"""
    iifname "{lan}" oifname "{wan}" accept
    iifname "{wan}" oifname "{lan}" ct state established,related accept"""
    return f"""#!/usr/sbin/nft -f
flush table ip gfc_client_nat
table inet gfc_client_filter {{
  chain forward {{
    type filter hook forward priority filter; policy drop;{forward}
  }}
}}
{masq}
"""


def apply_network(
    *,
    wan: str | None = None,
    lan: str | None = None,
    force: bool = False,
) -> tuple[bool, str]:
    wan_iface, lan_iface, all_ifaces = detect_wan_lan(wan, lan)
    if not wan_iface:
        return False, "no physical network interfaces found"

    messages: list[str] = [f"ifaces={all_ifaces}", f"wan={wan_iface}", f"lan={lan_iface or 'none'}"]

    NETPLAN_FILE.write_text(render_netplan(wan_iface, lan_iface), encoding="utf-8")
    messages.append(f"netplan -> {NETPLAN_FILE}")

    if lan_iface:
        DNSMASQ_FILE.parent.mkdir(parents=True, exist_ok=True)
        DNSMASQ_FILE.write_text(render_dnsmasq(lan_iface), encoding="utf-8")
        messages.append(f"dnsmasq -> {DNSMASQ_FILE}")
    elif DNSMASQ_FILE.is_file():
        DNSMASQ_FILE.unlink()
        messages.append("dnsmasq disabled (no LAN)")

    NFT_BOOT.parent.mkdir(parents=True, exist_ok=True)
    NFT_BOOT.write_text(render_boot_nft(wan_iface, lan_iface), encoding="utf-8")
    messages.append(f"nft boot -> {NFT_BOOT}")

    _write_env_value("GFC_WAN_IFACE", wan_iface)
    if lan_iface:
        _write_env_value("GFC_LAN_IFACE", lan_iface)
    _write_env_value("GFC_PROXY_MODE", os.environ.get("GFC_PROXY_MODE", "gateway"))

    if Path("/usr/sbin/netplan").exists():
        r = _run(["netplan", "apply"])
        messages.append(f"netplan apply: {r.returncode}")

    if lan_iface and Path("/bin/systemctl").exists():
        _run(["systemctl", "enable", "dnsmasq"])
        r = _run(["systemctl", "restart", "dnsmasq"])
        messages.append(f"dnsmasq: {r.returncode}")

    if Path("/usr/sbin/nft").exists():
        r = _run(["nft", "-f", str(NFT_BOOT)])
        messages.append(f"nft: {r.returncode}")

    roles_path = GFC_ETC / "network-roles.json"
    roles_path.write_text(
        json.dumps(
            {
                "wan": wan_iface,
                "lan": lan_iface,
                "all": all_ifaces,
                "lanAddress": LAN_ADDRESS,
                "lanNetwork": f"{LAN_NETWORK}/{LAN_PREFIX}",
                "dhcpRange": [DHCP_START, DHCP_END],
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    return True, "; ".join(messages)


def network_status() -> dict[str, Any]:
    wan, lan, all_ifaces = detect_wan_lan()
    roles_file = GFC_ETC / "network-roles.json"
    roles: dict[str, Any] = {}
    if roles_file.is_file():
        try:
            roles = json.loads(roles_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            roles = {}
    return {
        "wan": wan,
        "lan": lan,
        "interfaces": all_ifaces,
        "lanAddress": LAN_ADDRESS,
        "lanPrefix": LAN_PREFIX,
        "lanNetwork": f"{LAN_NETWORK}/{LAN_PREFIX}",
        "gateway": LAN_ADDRESS,
        "netmask": LAN_NETMASK,
        "dhcp": {
            "enabled": bool(lan),
            "start": DHCP_START,
            "end": DHCP_END,
        },
        "roles": roles,
    }
