#!/bin/bash
# Load TPROXY nftables rules immediately (when gfc table missing).
_self="${BASH_SOURCE[0]:-$0}"
if grep -q $'\r' "$_self" 2>/dev/null; then
  sed -i 's/\r$//' "$_self"
  exec bash "$_self" "$@"
fi
set -euo pipefail
set -a
# shellcheck source=/dev/null
source /etc/gfc-node/gfc.env
set +a
TPROXY_IFACE="${GFC_TPROXY_IFACE:?Set GFC_TPROXY_IFACE in /etc/gfc-node/gfc.env}"
WAN_IFACE="${GFC_SNAT_IFACE:-auto}"
if [[ "$WAN_IFACE" == "auto" ]]; then
  WAN_IFACE="$(ip -4 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -1)"
fi
[[ -n "$WAN_IFACE" ]] || { echo "WAN iface unknown" >&2; exit 1; }
PORT=12345
nft delete table inet gfc 2>/dev/null || true
if [[ -f /etc/gfc-node/gfc.nft ]]; then
  nft -f /etc/gfc-node/gfc.nft
else
  cat >/etc/gfc-node/gfc.nft <<EOF
#!/usr/sbin/nft -f
# Emergency gfc.nft — docs/NFT_ARCHITECTURE.md
table inet gfc {
  set bypass_ip {
    type ipv4_addr
    flags interval
  }

  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;
    meta mark 0x00000100 return
    ip daddr { 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/8 } return
    ip daddr @bypass_ip return
    iifname "${WAN_IFACE}" return
    iifname "${TPROXY_IFACE}" meta l4proto tcp meta mark set 0x00000100 tproxy ip to :${PORT} accept
    iifname "${TPROXY_IFACE}" meta l4proto udp meta mark set 0x00000100 tproxy ip to :${PORT} accept
  }

  chain output {
    type route hook output priority mangle; policy accept;
    meta mark != 0x00000000 return
    tcp dport 212 return
    ip daddr { 10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/8 } return
    ip daddr @bypass_ip return
    meta mark set 0x00000001
    ct mark set meta mark
    oifname "${WAN_IFACE}" return
  }
}
EOF
  nft -f /etc/gfc-node/gfc.nft
fi
ip rule del fwmark 0x1 lookup 100 2>/dev/null || true
ip rule add fwmark 0x100 lookup 100 2>/dev/null || true
ip route replace local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
ip rule add fwmark 0x1 lookup 1 2>/dev/null || true
ip route replace default dev "$WAN_IFACE" table 1 2>/dev/null || true
echo "OK nft gfc table tproxy=${TPROXY_IFACE} wan=${WAN_IFACE} -> :${PORT}"
nft list table inet gfc
