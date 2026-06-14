#!/usr/bin/env bash
# Recover gfc-mosdns after OUTPUT DNS hijack / User=mosdns permission issues.
set -euo pipefail

GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
MOSDNS_PORT="${GFC_MOSDNS_PORT:-53}"
CFG="${GFC_ETC}/mosdns/easymosdns/config.yaml"
NFT_DNS="${GFC_ETC}/nftables-dns.conf"
GFC_ENV="${GFC_ENV_FILE:-${GFC_ETC}/gfc.env}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ "${EUID:-0}" -ne 0 ]]; then
  echo "Run as root: sudo bash deploy/fix-mosdns-start.sh"
  exit 1
fi

# shellcheck source=lib-mosdns-nft.sh
source "$SCRIPT_DIR/lib-mosdns-nft.sh"

echo "==> fix-mosdns-start"
migrate_mosdns_user
echo "    ${GFC_MOSDNS_USER} uid=$(id -u "$GFC_MOSDNS_USER")"

chattr -i /etc/resolv.conf 2>/dev/null || true
cat >/etc/resolv.conf <<'EOF'
nameserver 127.0.0.1
EOF
chmod 644 /etc/resolv.conf

if [[ -f "$CFG" ]]; then
  sed -i '/file: "\.\/mosdns.log"/d' "$CFG"
  sed -i "s/0.0.0.0:5335/0.0.0.0:${MOSDNS_PORT}/g" "$CFG"
fi

fix_mosdns_tree_perms "$GFC_ETC"

LAN="bridge_lan"
if [[ -f "$GFC_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$GFC_ENV"
  LAN="${GFC_LAN_IFACE:-${GFC_BRIDGE_NAME:-bridge_lan}}"
fi
write_gfc_nft_dns_conf "$LAN" "$MOSDNS_PORT" "$NFT_DNS"
chmod 644 "$NFT_DNS"
apply_gfc_nft_dns_conf "$NFT_DNS"
echo "    nft dns hijack (lan=${LAN}, exclude uid=${GFC_MOSDNS_UID})"

cat >/etc/systemd/system/gfc-mosdns.service <<EOF
[Unit]
Description=GFC MosDNS (sole DNS :53)
After=gfc-network.service
Wants=gfc-network.service
Before=gfc-sing-box.service

[Service]
Type=simple
User=${GFC_MOSDNS_USER}
Group=${GFC_MOSDNS_USER}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
WorkingDirectory=/etc/gfc-client/mosdns/easymosdns
ExecStart=/usr/local/bin/mosdns start -c /etc/gfc-client/mosdns/easymosdns/config.yaml
Restart=on-failure
RestartSec=3
StandardOutput=append:/var/log/gfc-client/mosdns.log
StandardError=append:/var/log/gfc-client/mosdns.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl reset-failed gfc-mosdns.service 2>/dev/null || true
systemctl restart gfc-mosdns.service
sleep 2

if systemctl is-active --quiet gfc-mosdns.service; then
  echo "OK  gfc-mosdns active"
else
  echo "FAIL gfc-mosdns — last log lines:"
  journalctl -u gfc-mosdns -n 20 --no-pager || true
  tail -20 /var/log/gfc-client/mosdns.log 2>/dev/null || true
  exit 1
fi

if dig @127.0.0.1 baidu.com +time=2 +tries=1 +short | grep -q .; then
  echo "OK  dig baidu.com"
else
  echo "WARN dig baidu.com failed (may need sing-box for foreign domains)"
fi

ss -ulnp | grep ':53 ' || true
echo "==> fix-mosdns-start done"
