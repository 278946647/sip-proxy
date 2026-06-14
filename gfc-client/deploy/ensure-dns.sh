#!/usr/bin/env bash
# Layer 4 — DNS prep only (run immediately before gfc-mosdns). Does not start MosDNS.
set -euo pipefail

GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
MOSDNS_PORT="${GFC_MOSDNS_PORT:-53}"

echo "==> ensure-dns"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-mosdns-nft.sh
source "$SCRIPT_DIR/lib-mosdns-nft.sh"
migrate_mosdns_user

# 4a. Stub resolver must be off before MosDNS binds :53
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

# 4b. MosDNS must listen on :53 (not legacy :5335)
CFG="${GFC_ETC}/mosdns/easymosdns/config.yaml"
FIXED=0
if [[ -f "$CFG" ]]; then
  if grep -q 'file: "./mosdns.log"' "$CFG"; then
    sed -i '/file: "\.\/mosdns.log"/d' "$CFG"
    FIXED=1
  fi
  if grep -q '0.0.0.0:5335' "$CFG"; then
    echo "    fix mosdns :5335 -> :${MOSDNS_PORT}"
    sed -i "s/0.0.0.0:5335/0.0.0.0:${MOSDNS_PORT}/g" "$CFG"
    FIXED=1
  fi
  if ! grep -qE "addr: \"0\\.0\\.0\\.0:${MOSDNS_PORT}\"" "$CFG"; then
    if command -v gfc-bootstrap >/dev/null; then
      echo "    render mosdns via gfc-bootstrap..."
      gfc-bootstrap || true
      FIXED=1
    fi
  fi
  if [[ "$FIXED" == "1" ]]; then
    systemctl try-restart gfc-mosdns.service 2>/dev/null || true
    sleep 1
  fi
fi

fix_mosdns_tree_perms "$GFC_ETC"

# 4c. OUTPUT DNS hijack — exclude fixed mosdns uid
NFT_DNS="${GFC_ETC}/nftables-dns.conf"
LAN="bridge_lan"
GFC_ENV="${GFC_ENV_FILE:-${GFC_ETC}/gfc.env}"
if [[ -f "$GFC_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$GFC_ENV"
  LAN="${GFC_LAN_IFACE:-${GFC_BRIDGE_NAME:-bridge_lan}}"
fi
write_gfc_nft_dns_conf "$LAN" "$MOSDNS_PORT" "$NFT_DNS"
apply_gfc_nft_dns_conf "$NFT_DNS"
echo "    nft output_dns excludes uid ${GFC_MOSDNS_UID}"

# 4d. Port conflict check
if command -v ss >/dev/null; then
  echo "    listeners on udp/53:"
  ss -ulnp | grep ':53 ' || echo "      (none)"
fi

echo "==> ensure-dns done"
