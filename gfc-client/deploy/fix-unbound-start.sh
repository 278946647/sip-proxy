#!/usr/bin/env bash
# Recover gfc-unbound after OUTPUT DNS hijack / permission issues.
set -euo pipefail

GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
DNS_PORT="${GFC_DNS_PORT:-53}"
UNBOUND_CFG="/etc/unbound/unbound.conf"
NFT_DNS="${GFC_ETC}/nftables-dns.conf"
GFC_ENV="${GFC_ENV_FILE:-${GFC_ETC}/gfc.env}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ "${EUID:-0}" -ne 0 ]]; then
  echo "Run as root: sudo bash deploy/fix-unbound-start.sh"
  exit 1
fi

# shellcheck source=lib-unbound-nft.sh
source "$SCRIPT_DIR/lib-unbound-nft.sh"

echo "==> fix-unbound-start"
migrate_unbound_user
echo "    ${GFC_UNBOUND_USER} uid=$(id -u "$GFC_UNBOUND_USER")"

chattr -i /etc/resolv.conf 2>/dev/null || true
cat >/etc/resolv.conf <<'EOF'
nameserver 127.0.0.1
EOF
chmod 644 /etc/resolv.conf

if command -v gfc-bootstrap >/dev/null; then
  gfc-bootstrap || true
fi

fix_unbound_tree_perms "$GFC_ETC"

LAN="bridge_lan"
if [[ -f "$GFC_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$GFC_ENV"
  LAN="${GFC_LAN_IFACE:-${GFC_BRIDGE_NAME:-bridge_lan}}"
fi
write_gfc_nft_dns_conf "$LAN" "$DNS_PORT" "$NFT_DNS"
chmod 644 "$NFT_DNS"
apply_gfc_nft_dns_conf "$NFT_DNS"
echo "    nft dns hijack (lan=${LAN}, exclude uid=${GFC_UNBOUND_UID})"

UNBOUND_BIN="/usr/sbin/unbound"
if [[ ! -x "$UNBOUND_BIN" ]]; then
  UNBOUND_BIN="/usr/local/sbin/unbound"
fi

cat >/etc/systemd/system/gfc-unbound.service <<EOF
[Unit]
Description=GFC Unbound (sole DNS :53)
After=gfc-network.service
Wants=gfc-network.service
Before=gfc-sing-box.service

[Service]
Type=simple
User=${GFC_UNBOUND_USER}
Group=${GFC_UNBOUND_USER}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ExecStart=${UNBOUND_BIN} -d -c ${UNBOUND_CFG}
Restart=on-failure
RestartSec=3
StandardOutput=append:/var/log/gfc-client/unbound.log
StandardError=append:/var/log/gfc-client/unbound.log

[Install]
WantedBy=multi-user.target
EOF

systemctl disable --now gfc-mosdns.service 2>/dev/null || true
systemctl daemon-reload
systemctl reset-failed gfc-unbound.service 2>/dev/null || true
systemctl enable gfc-unbound.service 2>/dev/null || true
systemctl restart gfc-unbound.service
sleep 2

if systemctl is-active --quiet gfc-unbound.service; then
  echo "OK  gfc-unbound active"
else
  echo "FAIL gfc-unbound — last log lines:"
  journalctl -u gfc-unbound -n 20 --no-pager || true
  tail -20 /var/log/gfc-client/unbound.log 2>/dev/null || true
  exit 1
fi

if dig @127.0.0.1 baidu.com +time=2 +tries=1 +short | grep -q .; then
  echo "OK  dig baidu.com"
else
  echo "WARN dig baidu.com failed"
fi

ss -ulnp | grep ':53 ' || true
echo "==> fix-unbound-start done"
