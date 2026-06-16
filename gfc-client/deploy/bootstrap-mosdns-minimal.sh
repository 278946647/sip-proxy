#!/usr/bin/env bash
# Emergency MosDNS: write GFC minimal split-DNS config (no Go build / no easymosdns).
set -euo pipefail

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
MOSDNS_PORT="${GFC_MOSDNS_PORT:-53}"
BASE="${GFC_ETC}/mosdns/easymosdns"
CFG="${BASE}/config.yaml"
RULES="${BASE}/rules"
TMPL="${GFC_ROOT}/share/gfc-mosdns/config.yaml"
BUNDLE_RULES="${GFC_ROOT}/share/easymosdns/rules"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ "${EUID:-0}" -ne 0 ]]; then
  echo "Run as root: sudo bash deploy/bootstrap-mosdns-minimal.sh"
  exit 1
fi

# shellcheck source=lib-mosdns-nft.sh
source "$SCRIPT_DIR/lib-mosdns-nft.sh"

echo "==> bootstrap-mosdns-minimal"
migrate_mosdns_user || ensure_mosdns_user

mkdir -p "$RULES"
for f in china_domain_list.txt gfw_domain_list.txt; do
  if [[ ! -f "${RULES}/${f}" ]]; then
    if [[ -f "${BUNDLE_RULES}/${f}" ]]; then
      cp -f "${BUNDLE_RULES}/${f}" "${RULES}/${f}"
    else
      echo "ERROR: missing ${RULES}/${f} (sync gfc-client share/easymosdns/rules)" >&2
      exit 1
    fi
  fi
done

if [[ ! -f "$TMPL" ]]; then
  echo "ERROR: template missing: $TMPL" >&2
  exit 1
fi

sed \
  -e "s|__RULES_DIR__|${RULES}|g" \
  -e "s|__MOSDNS_PORT__|${MOSDNS_PORT}|g" \
  "$TMPL" >"$CFG"
chmod 644 "$CFG"
fix_mosdns_tree_perms "$GFC_ETC"

echo "    config -> $CFG"
if ! /usr/local/bin/mosdns start -c "$CFG" 2>&1 | head -5; then
  echo "WARN: mosdns dry-run printed errors (may be ok if port busy)"
fi

systemctl reset-failed gfc-mosdns.service 2>/dev/null || true
systemctl restart gfc-mosdns.service
sleep 2

if systemctl is-active --quiet gfc-mosdns.service; then
  echo "OK  gfc-mosdns active (minimal profile)"
else
  echo "FAIL gfc-mosdns — log:"
  journalctl -u gfc-mosdns -n 25 --no-pager || true
  exit 1
fi

if dig @127.0.0.1 baidu.com +time=2 +tries=1 +short | grep -q .; then
  echo "OK  dig baidu.com"
else
  echo "WARN dig baidu.com failed"
fi

echo "==> bootstrap-mosdns-minimal done"
