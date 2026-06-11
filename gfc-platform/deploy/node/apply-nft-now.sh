#!/bin/bash
# Load TPROXY nftables rules immediately (when gfc table missing).
_self="${BASH_SOURCE[0]:-$0}"
if grep -q $'\r' "$_self" 2>/dev/null; then
  sed -i 's/\r$//' "$_self"
  exec bash "$_self" "$@"
fi
set -euo pipefailset -a
# shellcheck source=/dev/null
source /etc/gfc-node/gfc.env
set +a
IFACE="${GFC_TPROXY_IFACE:?Set GFC_TPROXY_IFACE in /etc/gfc-node/gfc.env}"
PORT=12345
nft delete table inet gfc 2>/dev/null || true
if [[ -f /etc/gfc-node/gfc.nft ]]; then
  nft -f /etc/gfc-node/gfc.nft
else
  cat >/etc/gfc-node/gfc.nft <<EOF
#!/usr/sbin/nft -f
table inet gfc {
  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;
    iifname "$IFACE" ip protocol tcp meta mark set 0x1 tproxy ip to :$PORT accept
    iifname "$IFACE" ip protocol udp meta mark set 0x1 tproxy ip to :$PORT accept
  }
  chain output {
    type route hook output priority mangle; policy accept;
    ip protocol tcp meta mark 0x1 meta mark set 0x1 accept
    ip protocol udp meta mark 0x1 meta mark set 0x1 accept
  }
}
EOF
  nft -f /etc/gfc-node/gfc.nft
fi
ip rule add fwmark 0x1 lookup 100 2>/dev/null || true
ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
echo "OK nft gfc table on $IFACE -> :$PORT"
nft list table inet gfc
