#!/usr/bin/env bash
# Refresh EasyMosDNS template + re-render mosdns (via local API)
set -euo pipefail

SOURCE="${1:-github}"
case "$SOURCE" in
  github|cdn) ;;
  *)
    echo "Usage: sudo bash fetch-easymosdns-lists.sh [github|cdn]"
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-api-url.sh
source "$SCRIPT_DIR/lib-api-url.sh"
API="${GFC_API_URL:-$(gfc_admin_api_url)}"
echo "==> easymosdns update source=$SOURCE"
curl -fsS -X POST "${API}/dns/easymosdns/update" \
  -H 'Content-Type: application/json' \
  -d "{\"source\":\"${SOURCE}\"}"
echo
