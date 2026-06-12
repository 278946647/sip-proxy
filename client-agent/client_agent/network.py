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
BRIDGE_CONFIG_FILE = GFC_ETC / "network-bridge.json"

DEFAULT_BRIDGE_NAME = os.environ.get("GFC_BRIDGE_NAME", "bridge_lan")
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
        if name.startswith(DEFAULT_BRIDGE_NAME):
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
    cfg = load_bridge_config()
    ifaces = list_physical_interfaces()
    if not ifaces:
        return wan, lan, ifaces

    wan_iface = (wan or cfg.get("wan") or os.environ.get("GFC_WAN_IFACE") or "").strip() or ifaces[0]

    if cfg.get("mode") == "bridge" and cfg.get("bridgeName"):
        lan_iface = (lan or cfg["bridgeName"]).strip()
        return wan_iface, lan_iface, ifaces

    remaining = [i for i in ifaces if i != wan_iface]
    lan_iface = (lan or os.environ.get("GFC_LAN_IFACE") or "").strip()
    if not lan_iface and remaining:
        lan_iface = remaining[0]
    return wan_iface, lan_iface or None, ifaces


def default_bridge_config() -> dict[str, Any]:
    ifaces = list_physical_interfaces()
    wan = ifaces[0] if ifaces else ""
    members: list[str] = [ifaces[-1]] if len(ifaces) >= 2 else []
    return {
        "mode": "bridge",
        "bridgeName": DEFAULT_BRIDGE_NAME,
        "wan": wan,
        "members": members,
        "lanAddress": LAN_ADDRESS,
        "lanPrefix": LAN_PREFIX,
        "dhcpStart": DHCP_START,
        "dhcpEnd": DHCP_END,
    }


def load_bridge_config() -> dict[str, Any]:
    if BRIDGE_CONFIG_FILE.is_file():
        try:
            data = json.loads(BRIDGE_CONFIG_FILE.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return {**default_bridge_config(), **data}
        except (OSError, json.JSONDecodeError):
            pass
    return default_bridge_config()


def save_bridge_config(data: dict[str, Any]) -> dict[str, Any]:
    cfg = default_bridge_config()
    cfg.update({k: v for k, v in data.items() if v is not None})
    cfg["mode"] = "bridge"
    if not cfg.get("bridgeName"):
        cfg["bridgeName"] = DEFAULT_BRIDGE_NAME
    members = cfg.get("members") or []
    if isinstance(members, str):
        members = [m.strip() for m in members.split(",") if m.strip()]
    cfg["members"] = [m for m in members if m in list_physical_interfaces()]
    BRIDGE_CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    BRIDGE_CONFIG_FILE.write_text(
        json.dumps(cfg, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return cfg


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


def render_netplan_bridge(cfg: dict[str, Any]) -> str:
    wan = cfg["wan"]
    bridge = cfg["bridgeName"]
    members: list[str] = cfg.get("members") or []
    addr = cfg.get("lanAddress", LAN_ADDRESS)
    prefix = int(cfg.get("lanPrefix", LAN_PREFIX))

    eth_lines = [
        f"""    {wan}:
      dhcp4: true
      optional: true""",
    ]
    for m in members:
        if m == wan:
            continue
        eth_lines.append(
            f"""    {m}:
      dhcp4: false
      optional: true"""
        )

    member_yaml = ", ".join(members) if members else ""
    bridge_block = f"""
  bridges:
    {bridge}:
      interfaces: [{member_yaml}]
      addresses:
        - {addr}/{prefix}
      parameters:
        stp: false
        forward-delay: 0
      optional: true"""

    return f"""# GFC client — WAN + LAN bridge (managed by gfc-client-agent)
network:
  version: 2
  renderer: networkd
  ethernets:
{chr(10).join(eth_lines)}
{bridge_block}
"""


def render_netplan_direct(wan: str, lan: str | None) -> str:
    lan_block = ""
    if lan:
        lan_block = f"""
    {lan}:
      dhcp4: false
      addresses:
        - {LAN_ADDRESS}/{LAN_PREFIX}
      optional: true"""
    return f"""# GFC client — OpenWrt-style WAN/LAN direct (managed by gfc-client-agent)
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
    input_rules = "    ct state established,related accept\n    iif lo accept"
    if wan and lan:
        forward = f"""
    iifname "{lan}" oifname "{wan}" accept
    iifname "{wan}" oifname "{lan}" ct state established,related accept"""
        input_rules += f"""
    iifname "{lan}" tcp dport {{ 80, 81, 443, 22 }} accept
    iifname "{lan}" udp dport {{ 53, 67, 68 }} accept
    iifname "{lan}" icmp type echo-request accept"""
    return f"""#!/usr/sbin/nft -f
flush table ip gfc_client_nat
flush table inet gfc_client_filter
table inet gfc_client_filter {{
  chain input {{
    type filter hook input priority filter; policy drop;
{input_rules}
  }}
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
    bridge_config: dict[str, Any] | None = None,
    force: bool = False,
) -> tuple[bool, str]:
    if bridge_config:
        cfg = save_bridge_config(bridge_config)
    else:
        cfg = load_bridge_config()

    ifaces = list_physical_interfaces()
    if not ifaces:
        return False, "no physical network interfaces found"

    wan_iface = (wan or cfg.get("wan") or "").strip() or ifaces[0]
    cfg["wan"] = wan_iface

    use_bridge = cfg.get("mode") == "bridge" and cfg.get("bridgeName")
    if use_bridge:
        if not cfg.get("members"):
            remaining = [i for i in ifaces if i != wan_iface]
            cfg["members"] = [remaining[-1]] if remaining else []
            save_bridge_config(cfg)
        lan_iface = cfg["bridgeName"]
        netplan = render_netplan_bridge(cfg)
    else:
        _, lan_iface, _ = detect_wan_lan(wan_iface, lan)
        netplan = render_netplan_direct(wan_iface, lan_iface)

    messages: list[str] = [
        f"ifaces={ifaces}",
        f"wan={wan_iface}",
        f"lan={lan_iface or 'none'}",
        f"mode={'bridge' if use_bridge else 'direct'}",
    ]
    if use_bridge:
        messages.append(f"bridge_members={cfg.get('members')}")

    NETPLAN_FILE.write_text(netplan, encoding="utf-8")
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
    if use_bridge:
        _write_env_value("GFC_BRIDGE_NAME", cfg["bridgeName"])
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
                "all": ifaces,
                "mode": cfg.get("mode", "bridge"),
                "bridgeName": cfg.get("bridgeName"),
                "bridgeMembers": cfg.get("members", []),
                "lanAddress": cfg.get("lanAddress", LAN_ADDRESS),
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
    cfg = load_bridge_config()
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
        "bridge": cfg,
        "lanAddress": LAN_ADDRESS,
        "lanPrefix": LAN_PREFIX,
        "lanNetwork": f"{LAN_NETWORK}/{LAN_PREFIX}",
        "gateway": LAN_ADDRESS,
        "netmask": LAN_NETMASK,
        "dhcp": {
            "enabled": bool(lan),
            "start": DHCP_START,
            "end": DHCP_END,
            "interface": lan,
        },
        "roles": roles,
    }
