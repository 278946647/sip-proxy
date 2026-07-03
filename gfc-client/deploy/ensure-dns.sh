#!/usr/bin/env bash
# Layer 4 — DNS prep only (run immediately before gfc-unbound). Does not start Unbound.
set -euo pipefail

GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
DNS_PORT="${GFC_DNS_PORT:-53}"

echo "==> ensure-dns"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-unbound-nft.sh
source "$SCRIPT_DIR/lib-unbound-nft.sh"
migrate_unbound_user

if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  echo "    stop systemd-resolved..."
  systemctl disable --now systemd-resolved 2>/dev/null || systemctl stop systemd-resolved 2>/dev/null || true
fi
if [[ -L /etc/resolv.conf ]]; then
  rm -f /etc/resolv.conf
fi
chattr -i /etc/resolv.conf 2>/dev/null || true
cat >/etc/resolv.conf <<'EOF'
nameserver 127.0.0.1
EOF
chmod 644 /etc/resolv.conf
echo "    resolv.conf -> 127.0.0.1"

if command -v gfc-bootstrap >/dev/null; then
  echo "    render unbound via gfc-bootstrap..."
  gfc-bootstrap || true
  systemctl try-restart gfc-unbound.service 2>/dev/null || true
  sleep 1
fi

fix_unbound_tree_perms "$GFC_ETC"

NFT_DNS="${GFC_ETC}/nftables-dns.conf"
LAN="bridge_lan"
GFC_ENV="${GFC_ENV_FILE:-${GFC_ETC}/gfc.env}"
if [[ -f "$GFC_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$GFC_ENV"
  LAN="${GFC_LAN_IFACE:-${GFC_BRIDGE_NAME:-bridge_lan}}"
fi
write_gfc_nft_dns_conf "$LAN" "$DNS_PORT" "$NFT_DNS"
apply_gfc_nft_dns_conf "$NFT_DNS"
echo "    nft output_dns excludes uid ${GFC_UNBOUND_UID}"

if command -v ss >/dev/null; then
  echo "    listeners on udp/53:"
  ss -ulnp | grep ':53 ' || echo "      (none)"
fi

echo "==> ensure-dns done"
