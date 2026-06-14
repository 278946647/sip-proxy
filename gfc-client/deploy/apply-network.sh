#!/usr/bin/env bash
# OpenWrt-style WAN/LAN: netplan + dnsmasq + nft (bridge or direct)
set -euo pipefail

GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
GFC_ENV="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
BRIDGE_CFG="${GFC_ETC}/network-bridge.json"
NETPLAN_FILE="/etc/netplan/99-gfc-client.yaml"
DNSMASQ_FILE="/etc/dnsmasq.d/gfc-client.conf"
NFT_BOOT="${GFC_ETC}/gfc-boot.nft"
NFT_DNS="${GFC_ETC}/gfc-dns.nft"
MOSDNS_PORT="${GFC_MOSDNS_PORT:-5335}"

LAN_ADDRESS="${GFC_LAN_ADDRESS:-192.168.68.1}"
LAN_PREFIX="${GFC_LAN_PREFIX:-24}"
LAN_NETWORK="${GFC_LAN_NETWORK:-192.168.68.0}"
LAN_NETMASK="${GFC_LAN_NETMASK:-255.255.255.0}"
DHCP_START="${GFC_DHCP_START:-192.168.68.100}"
DHCP_END="${GFC_DHCP_END:-192.168.68.250}"
BRIDGE_NAME="${GFC_BRIDGE_NAME:-bridge_lan}"

[[ -f "$GFC_ENV" ]] && set -a && source "$GFC_ENV" && set +a

mkdir -p "$GFC_ETC"

eval "$(python3 - <<'PY'
import json, os, re
from pathlib import Path

GFC_ETC = Path(os.environ.get("GFC_ETC", "/etc/gfc-client"))
BRIDGE_CFG = GFC_ETC / "network-bridge.json"
LAN_ADDRESS = os.environ.get("GFC_LAN_ADDRESS", "192.168.68.1")
LAN_PREFIX = int(os.environ.get("GFC_LAN_PREFIX", "24"))
BRIDGE_NAME = os.environ.get("GFC_BRIDGE_NAME", "bridge_lan")
skip = re.compile(r"^(lo|docker\d*|veth.*|br-.*|virbr\d*|tailscale\d*|wg\d*|tun\d*|gfc\d*|gfctun)$")

def list_ifaces():
    net = Path("/sys/class/net")
    names = []
    for p in net.iterdir():
        n = p.name
        if skip.match(n) or n.startswith(BRIDGE_NAME):
            continue
        if (p / "device").exists() or n.startswith(("eth", "en", "eno", "ens", "enp")):
            names.append(n)
    names.sort(key=lambda x: (int(re.search(r"(\d+)$", x).group(1)) if re.search(r"(\d+)$", x) else 0, x))
    return names

def default_cfg(ifaces):
    wan = ifaces[0] if ifaces else ""
    members = [ifaces[-1]] if len(ifaces) >= 2 else []
    return {
        "mode": "bridge", "bridgeName": BRIDGE_NAME, "wan": wan, "members": members,
        "lanAddress": LAN_ADDRESS, "lanPrefix": LAN_PREFIX,
        "dhcpStart": os.environ.get("GFC_DHCP_START", "192.168.68.100"),
        "dhcpEnd": os.environ.get("GFC_DHCP_END", "192.168.68.250"),
    }

ifaces = list_ifaces()
cfg = default_cfg(ifaces)
if BRIDGE_CFG.is_file():
    try:
        cfg.update({**default_cfg(ifaces), **json.loads(BRIDGE_CFG.read_text())})
    except Exception:
        pass

wan = (os.environ.get("GFC_WAN_IFACE") or cfg.get("wan") or (ifaces[0] if ifaces else "")).strip()
cfg["wan"] = wan
use_bridge = cfg.get("mode") == "bridge" and cfg.get("bridgeName")
if use_bridge:
    if not cfg.get("members"):
        rem = [i for i in ifaces if i != wan]
        cfg["members"] = [rem[-1]] if rem else []
    lan = cfg["bridgeName"]
else:
    rem = [i for i in ifaces if i != wan]
    lan = (os.environ.get("GFC_LAN_IFACE") or (rem[0] if rem else "")).strip()

BRIDGE_CFG.write_text(json.dumps(cfg, ensure_ascii=False, indent=2))

print(f'WAN="{wan}"')
print(f'LAN="{lan}"')
print(f'USE_BRIDGE={"1" if use_bridge else "0"}')
print(f'IFACES="{" ".join(ifaces)}"')
print(f'BRIDGE_MEMBERS="{" ".join(cfg.get("members") or [])}"')
PY
)"

echo "==> network wan=$WAN lan=${LAN:-none} bridge=$USE_BRIDGE ifaces=$IFACES"

if [[ "$USE_BRIDGE" == "1" ]]; then
  python3 - "$NETPLAN_FILE" "$WAN" "$LAN" "$BRIDGE_MEMBERS" "$LAN_ADDRESS" "$LAN_PREFIX" <<'PY'
import sys
from pathlib import Path
netplan, wan, bridge, members, addr, prefix = sys.argv[1:7]
ms = [m for m in members.split() if m and m != wan]
eth = [f"    {wan}:\n      dhcp4: true\n      optional: true"]
for m in ms:
    eth.append(f"    {m}:\n      dhcp4: false\n      optional: true")
member_yaml = ", ".join(ms)
text = f"""# GFC client — WAN + LAN bridge
network:
  version: 2
  renderer: networkd
  ethernets:
{chr(10).join(eth)}
  bridges:
    {bridge}:
      interfaces: [{member_yaml}]
      addresses:
        - {addr}/{prefix}
      parameters:
        stp: false
        forward-delay: 0
      optional: true
"""
Path(netplan).write_text(text)
Path(netplan).chmod(0o600)
PY
else
  python3 - "$NETPLAN_FILE" "$WAN" "$LAN" "$LAN_ADDRESS" "$LAN_PREFIX" <<'PY'
import sys
from pathlib import Path
netplan, wan, lan, addr, prefix = sys.argv[1:6]
lan_block = ""
if lan:
    lan_block = f"""
    {lan}:
      dhcp4: false
      addresses:
        - {addr}/{prefix}
      optional: true"""
text = f"""# GFC client — WAN/LAN direct
network:
  version: 2
  renderer: networkd
  ethernets:
    {wan}:
      dhcp4: true
      optional: true{lan_block}
"""
Path(netplan).write_text(text)
Path(netplan).chmod(0o600)
PY
fi
echo "    netplan -> $NETPLAN_FILE"

if [[ -n "${LAN:-}" ]]; then
  cat >"$DNSMASQ_FILE" <<EOF
# GFC client LAN DHCP; DNS via nft redirect to mosdns :${MOSDNS_PORT}
interface=${LAN}
bind-interfaces
except-interface=lo
listen-address=${LAN_ADDRESS}
port=0
dhcp-range=${DHCP_START},${DHCP_END},${LAN_NETMASK},12h
dhcp-option=option:router,${LAN_ADDRESS}
dhcp-option=option:dns-server,${LAN_ADDRESS}
cache-size=1000
EOF
  echo "    dnsmasq -> $DNSMASQ_FILE"
else
  rm -f "$DNSMASQ_FILE"
  echo "    dnsmasq disabled"
fi

python3 - "$NFT_BOOT" "$WAN" "$LAN" "$MOSDNS_PORT" <<'PY'
import sys
from pathlib import Path
nft_boot, wan, lan, mosdns_port = sys.argv[1:5]
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
    iifname "{lan}" tcp dport {{ 22, 80, 81, 443 }} accept
    iifname "{lan}" udp dport {{ 53, 67, 68, {mosdns_port} }} accept
    iifname "{lan}" tcp dport {{ 53, {mosdns_port} }} accept
    iifname "{lan}" icmp type echo-request accept"""
text = f"""#!/usr/sbin/nft -f
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
Path(nft_boot).write_text(text)
PY
echo "    nft boot -> $NFT_BOOT"

if [[ -n "${LAN:-}" ]]; then
  cat >"$NFT_DNS" <<EOF
#!/usr/sbin/nft -f
table inet gfc_dns {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "${LAN}" udp dport 53 redirect to :${MOSDNS_PORT}
    iifname "${LAN}" tcp dport 53 redirect to :${MOSDNS_PORT}
  }
}
EOF
  echo "    nft dns -> $NFT_DNS"
fi

update_env() {
  local key=$1 val=$2
  local file="$GFC_ENV"
  touch "$file"
  chmod 600 "$file"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
}
update_env GFC_WAN_IFACE "$WAN"
[[ -n "${LAN:-}" ]] && update_env GFC_LAN_IFACE "$LAN"
[[ "$USE_BRIDGE" == "1" ]] && update_env GFC_BRIDGE_NAME "$LAN"

python3 - "$GFC_ETC/network-roles.json" "$WAN" "$LAN" "$IFACES" "$USE_BRIDGE" "$LAN_ADDRESS" "$LAN_PREFIX" "$LAN_NETWORK" "$DHCP_START" "$DHCP_END" <<'PY'
import json, sys
from pathlib import Path
path, wan, lan, ifaces, use_bridge, addr, prefix, network, dhcp_s, dhcp_e = sys.argv[1:11]
Path(path).write_text(json.dumps({
    "wan": wan, "lan": lan, "all": ifaces.split(),
    "mode": "bridge" if use_bridge == "1" else "direct",
    "lanAddress": addr, "lanNetwork": f"{network}/{prefix}",
    "dhcpRange": [dhcp_s, dhcp_e],
}, ensure_ascii=False, indent=2))
PY

if command -v netplan >/dev/null; then
  chmod 600 /etc/netplan/*.yaml 2>/dev/null || true
  netplan apply && echo "    netplan apply: ok"
fi
if [[ -n "${LAN:-}" ]] && command -v systemctl >/dev/null; then
  systemctl enable dnsmasq
  systemctl restart dnsmasq && echo "    dnsmasq: ok"
fi
if command -v nft >/dev/null; then
  nft list table ip gfc_client_nat &>/dev/null && nft delete table ip gfc_client_nat || true
  nft list table inet gfc_client_filter &>/dev/null && nft delete table inet gfc_client_filter || true
  nft -f "$NFT_BOOT" && echo "    nft boot: ok"
  if [[ -f "$NFT_DNS" ]]; then
    nft list table inet gfc_dns &>/dev/null && nft delete table inet gfc_dns || true
    nft -f "$NFT_DNS" && echo "    nft dns: ok"
  fi
fi

echo "==> network apply done"
