#!/usr/bin/env bash
# Download MetaCubeX meta-rules-dat .srs into /var/lib/gfc-client/rules
set -euo pipefail

GFC_LIB="${GFC_LIB:-/var/lib/gfc-client}"
RULES_DIR="${RULES_DIR:-${GFC_LIB}/rules}"
BASE="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo"

mkdir -p "$RULES_DIR"

fetch_one() {
  local name=$1 url=$2
  echo "==> $name"
  curl -fsSL --connect-timeout 20 --max-time 180 \
    --dns-servers 223.5.5.5 --dns-servers 119.29.29.29 \
    --dns-servers 8.8.8.8 --dns-servers 1.1.1.1 \
    -o "${RULES_DIR}/${name}" "$url"
  ls -la "${RULES_DIR}/${name}"
}

fetch_one geosite-cn.srs "${BASE}/geosite/cn.srs"
fetch_one geoip-cn.srs "${BASE}/geoip/cn.srs"
fetch_one geosite-geolocation-not-cn.srs "${BASE}/geosite/geolocation-!cn.srs"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-api-url.sh
source "$SCRIPT_DIR/lib-api-url.sh"
API="$(gfc_admin_api_url)"
echo "==> meta-rules ready under ${RULES_DIR}"
if command -v curl >/dev/null && curl -fsS --connect-timeout 2 "${API}/dataplane/reload" >/dev/null 2>&1; then
  echo "==> reload dataplane via API (${API})"
  curl -fsS -X POST "${API}/dataplane/reload" || true
fi
