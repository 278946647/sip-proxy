#!/usr/bin/env bash
# WAN/LAN: netplan + dnsmasq (DHCP only) + nftables (filter/nat/dns hijack)
set -euo pipefail

GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
GFC_ENV="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
BRIDGE_CFG="${GFC_ETC}/network-bridge.json"
NETPLAN_FILE="/etc/netplan/99-gfc-client.yaml"
DNSMASQ_FILE="/etc/dnsmasq.d/gfc-client.conf"
DNSMASQ_ETC="${GFC_ETC}/dnsmasq.conf"
NFT_BOOT="${GFC_ETC}/nftables.conf"
NFT_DNS="${GFC_ETC}/nftables-dns.conf"
NFT_POLICY="${GFC_ETC}/nftables-policy.conf"
TUN_IFACE="${GFC_TUN_INTERFACE:-gfctun}"
MOSDNS_PORT="${GFC_MOSDNS_PORT:-53}"
PROXY_MODE="${GFC_PROXY_MODE:-gateway}"

LAN_ADDRESS="${GFC_LAN_ADDRESS:-192.168.68.1}"
LAN_PREFIX="${GFC_LAN_PREFIX:-24}"
LAN_NETWORK="${GFC_LAN_NETWORK:-192.168.68.0}"
LAN_NETMASK="${GFC_LAN_NETMASK:-255.255.255.0}"
DHCP_START="${GFC_DHCP_START:-192.168.68.100}"
DHCP_END="${GFC_DHCP_END:-192.168.68.250}"
BRIDGE_NAME="${GFC_BRIDGE_NAME:-bridge_lan}"

[[ -f "$GFC_ENV" ]] && set -a && source "$GFC_ENV" && set +a
PROXY_MODE="${GFC_PROXY_MODE:-$PROXY_MODE}"
GFC_POLICY_MARK="${GFC_POLICY_MARK:-0x2023}"
GFC_POLICY_TABLE="${GFC_POLICY_TABLE:-2022}"
GFC_SSH_PORT="${GFC_SSH_PORT:-212}"
export GFC_POLICY_MARK GFC_POLICY_TABLE GFC_SSH_PORT

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

echo "==> network wan=$WAN lan=${LAN:-none} bridge=$USE_BRIDGE proxy=$PROXY_MODE ifaces=$IFACES"

if [[ "$USE_BRIDGE" == "1" ]]; then
  python3 - "$NETPLAN_FILE" "$WAN" "$LAN" "$BRIDGE_MEMBERS" "$LAN_ADDRESS" "$LAN_PREFIX" "$PROXY_MODE" <<'PY'
import os, sys
from pathlib import Path
netplan, wan, bridge, members, addr, prefix, proxy = sys.argv[1:8]
ms = [m for m in members.split() if m and m != wan]
policy = ""
if proxy in ("gateway", "transparent"):
    mark = int(os.environ.get("GFC_POLICY_MARK", "0x2023"), 0)
    table = int(os.environ.get("GFC_POLICY_TABLE", "2022"))
    policy = f"""
      routing-policy:
        - from: 0.0.0.0/0
          mark: {mark}
          table: {table}
          priority: 100"""
eth = [f"    {wan}:\n      dhcp4: true\n      optional: true{policy}"]
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
  python3 - "$NETPLAN_FILE" "$WAN" "$LAN" "$LAN_ADDRESS" "$LAN_PREFIX" "$PROXY_MODE" <<'PY'
import os, sys
from pathlib import Path
netplan, wan, lan, addr, prefix, proxy = sys.argv[1:7]
policy = ""
if proxy in ("gateway", "transparent"):
    mark = int(os.environ.get("GFC_POLICY_MARK", "0x2023"), 0)
    table = int(os.environ.get("GFC_POLICY_TABLE", "2022"))
    policy = f"""
      routing-policy:
        - from: 0.0.0.0/0
          mark: {mark}
          table: {table}
          priority: 100"""
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
      optional: true{policy}{lan_block}
"""
Path(netplan).write_text(text)
Path(netplan).chmod(0o600)
PY
fi
echo "    netplan -> $NETPLAN_FILE"

ENABLE_DHCP=1
if [[ "$PROXY_MODE" == "bypass" && "${GFC_BYPASS_DHCP:-0}" != "1" ]]; then
  ENABLE_DHCP=0
fi

if [[ -n "${LAN:-}" && "$ENABLE_DHCP" == "1" ]]; then
  cat >"$DNSMASQ_FILE" <<EOF
# GFC client — DHCP only (port=0, no DNS)
interface=${LAN}
bind-interfaces
except-interface=lo
listen-address=${LAN_ADDRESS}
port=0
dhcp-range=${DHCP_START},${DHCP_END},${LAN_NETMASK},12h
dhcp-option=option:router,${LAN_ADDRESS}
dhcp-option=option:dns-server,${LAN_ADDRESS}
EOF
  cp -f "$DNSMASQ_FILE" "$DNSMASQ_ETC"
  echo "    dnsmasq -> $DNSMASQ_FILE"
else
  rm -f "$DNSMASQ_FILE" "$DNSMASQ_ETC"
  echo "    dnsmasq disabled (proxy_mode=$PROXY_MODE)"
fi

ENABLE_MASQ=1
if [[ "$PROXY_MODE" == "bypass" ]]; then
  ENABLE_MASQ="${GFC_BYPASS_MASQ:-0}"
fi

python3 - "$NFT_BOOT" "$WAN" "$LAN" "$ENABLE_MASQ" "$TUN_IFACE" <<'PY'
import os, sys
from pathlib import Path
nft_boot, wan, lan, enable_masq, tun = sys.argv[1:6]
ssh_port = int(os.environ.get("GFC_SSH_PORT", "212"))
# Fresh Ubuntu listens on 22; production boxes use GFC_SSH_PORT (212). Allow both on all ifaces.
admin_tcp = sorted({22, ssh_port})
admin_tcp_set = ", ".join(str(p) for p in admin_tcp)
masq = ""
if wan and enable_masq == "1":
    masq = f"""
table ip gfc_client_nat {{
  chain postrouting {{
    type nat hook postrouting priority srcnat; policy accept;
    oifname "{wan}" masquerade
  }}
}}"""
forward = ""
input_rules = f"""    ct state established,related accept
    iif lo accept
    tcp dport {{ {admin_tcp_set} }} accept"""
if wan and lan:
    forward = f"""
    iifname "{lan}" oifname "{tun}" accept
    iifname "{tun}" oifname "{lan}" ct state established,related accept
    iifname "{lan}" oifname "{wan}" accept
    iifname "{wan}" oifname "{lan}" ct state established,related accept"""
    input_rules += f"""
    iifname "{lan}" tcp dport {{ 80, 443, 8080 }} accept
    iifname "{lan}" udp dport {{ 53, 67, 68 }} accept
    iifname "{lan}" tcp dport 53 accept
    iifname "{lan}" icmp type echo-request accept"""
text = f"""#!/usr/sbin/nft -f
table inet gfc_client_filter {{
  chain input {{
    type filter hook input priority -200; policy drop;
{input_rules}
  }}
  chain forward {{
    type filter hook forward priority -200; policy drop;{forward}
  }}
}}
{masq}
"""
Path(nft_boot).write_text(text)
PY
echo "    nft filter -> $NFT_BOOT"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-mosdns-nft.sh
source "$SCRIPT_DIR/lib-mosdns-nft.sh"
# shellcheck source=lib-singbox-user.sh
source "$SCRIPT_DIR/lib-singbox-user.sh"
# shellcheck source=lib-policy-routing.sh
source "$SCRIPT_DIR/lib-policy-routing.sh"
LAN_IF="${LAN:-bridge_lan}"
migrate_mosdns_user || ensure_mosdns_user
migrate_singbox_user || ensure_singbox_user
fix_singbox_tree_perms "$GFC_ETC"
write_gfc_nft_dns_conf "$LAN_IF" "$MOSDNS_PORT" "$NFT_DNS"
echo "    nft dns -> $NFT_DNS (exclude uid ${GFC_MOSDNS_UID})"

LAN_CIDR="${LAN_NETWORK}/${LAN_PREFIX}"
if gfc_policy_mode_enabled && [[ -n "${LAN:-}" ]]; then
  POLICY_BYPASS_IPS="$(resolve_policy_bypass_ips)"
  write_gfc_nft_policy_conf "$LAN_IF" "$LAN_CIDR" "$NFT_POLICY" "$POLICY_BYPASS_IPS"
  echo "    nft policy -> $NFT_POLICY (mark ${GFC_POLICY_MARK}, sing-box uid ${GFC_SINGBOX_UID:-65354})"
  [[ -n "$POLICY_BYPASS_IPS" ]] && echo "    nft bypass ips: ${POLICY_BYPASS_IPS}"
else
  rm -f "$NFT_POLICY"
  echo "    nft policy: skipped (proxy_mode=$PROXY_MODE)"
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
update_env GFC_MOSDNS_PORT "$MOSDNS_PORT"
update_env GFC_MOSDNS_UID "${GFC_MOSDNS_UID:-65353}"
update_env GFC_SINGBOX_UID "${GFC_SINGBOX_UID:-65354}"
update_env GFC_POLICY_MARK "${GFC_POLICY_MARK}"
update_env GFC_POLICY_TABLE "${GFC_POLICY_TABLE}"
update_env GFC_ROUTING_SCHEME "${GFC_ROUTING_SCHEME:-kernel-split}"
update_env GFC_SSH_PORT "${GFC_SSH_PORT}"
[[ -n "${LAN:-}" ]] && update_env GFC_LAN_IFACE "$LAN"
[[ -n "${LAN:-}" ]] && update_env GFC_LAN_CIDR "${LAN_NETWORK}/${LAN_PREFIX}"
[[ "$USE_BRIDGE" == "1" ]] && update_env GFC_BRIDGE_NAME "$LAN"

python3 - "$GFC_ETC/network-roles.json" "$WAN" "$LAN" "$IFACES" "$USE_BRIDGE" "$LAN_ADDRESS" "$LAN_PREFIX" "$LAN_NETWORK" "$DHCP_START" "$DHCP_END" "$PROXY_MODE" <<'PY'
import json, sys
from pathlib import Path
path, wan, lan, ifaces, use_bridge, addr, prefix, network, dhcp_s, dhcp_e, proxy = sys.argv[1:12]
Path(path).write_text(json.dumps({
    "wan": wan, "lan": lan, "all": ifaces.split(),
    "mode": "bridge" if use_bridge == "1" else "direct",
    "proxyMode": proxy,
    "lanAddress": addr, "lanNetwork": f"{network}/{prefix}",
    "dhcpRange": [dhcp_s, dhcp_e],
}, ensure_ascii=False, indent=2))
PY

if command -v netplan >/dev/null; then
  chmod 600 /etc/netplan/*.yaml 2>/dev/null || true
  if [[ "${GFC_SKIP_NETPLAN_APPLY:-0}" == "1" ]]; then
    echo "    netplan apply: skipped (GFC_SKIP_NETPLAN_APPLY=1)"
  else
    echo "    netplan apply (timeout 90s)..."
    if timeout 90 netplan apply; then
      echo "    netplan apply: ok"
    else
      echo "    WARN: netplan apply timed out or failed — set GFC_SKIP_NETPLAN_APPLY=1 to skip"
    fi
  fi
fi
if [[ -f "$DNSMASQ_FILE" ]] && command -v systemctl >/dev/null; then
  if [[ "${GFC_SKIP_NETPLAN_APPLY:-0}" == "1" ]]; then
    echo "    dnsmasq start: deferred (bridge not up until netplan apply)"
    systemctl stop dnsmasq 2>/dev/null || true
  elif [[ -n "${LAN:-}" ]] && ! ip link show "$LAN" &>/dev/null; then
    echo "    dnsmasq start: deferred (${LAN} not up yet)"
    systemctl stop dnsmasq 2>/dev/null || true
  else
    echo "    dnsmasq start..."
    systemctl stop dnsmasq 2>/dev/null || true
    if timeout 20 systemctl start dnsmasq; then
      echo "    dnsmasq: ok"
    else
      echo "    WARN: dnsmasq start timed out or failed"
    fi
  fi
elif command -v systemctl >/dev/null; then
  systemctl stop dnsmasq 2>/dev/null || true
fi
if command -v nft >/dev/null; then
  nft list table ip gfc_client_nat &>/dev/null && nft delete table ip gfc_client_nat || true
  nft list table inet gfc_client_filter &>/dev/null && nft delete table inet gfc_client_filter || true
  nft list table inet gfc_dns &>/dev/null && nft delete table inet gfc_dns || true
  nft list table inet gfc_dns_hijack &>/dev/null && nft delete table inet gfc_dns_hijack || true
  nft list table inet gfc_client_mangle &>/dev/null && nft delete table inet gfc_client_mangle || true
  nft -f "$NFT_BOOT" && echo "    nft filter: ok" || echo "    WARN: nft filter failed"
  nft -f "$NFT_DNS" && echo "    nft dns: ok" || echo "    WARN: nft dns failed"
  if [[ -f "$NFT_POLICY" ]]; then
    apply_gfc_nft_policy_conf "$NFT_POLICY" && echo "    nft policy: ok" || echo "    WARN: nft policy failed"
  else
    teardown_gfc_nft_policy 2>/dev/null || true
  fi
fi

if gfc_policy_mode_enabled; then
  echo "    policy routing (post-netplan)"
  ensure_policy_ip_rule || true
  ensure_policy_table_route || echo "    WARN: gfctun route deferred (sing-box not ready)"
fi

if [[ -f "${GFC_ETC}/sing-box.json" ]]; then
  bash "$SCRIPT_DIR/patch-singbox-wan.sh" || echo "    WARN: patch-singbox-wan failed"
fi

echo "==> network apply done"
