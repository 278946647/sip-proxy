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

API="${GFC_API_URL:-http://127.0.0.1/api/v1}"
echo "==> easymosdns update source=$SOURCE"
curl -fsS -X POST "${API}/dns/easymosdns/update" \
  -H 'Content-Type: application/json' \
  -d "{\"source\":\"${SOURCE}\"}"
echo
