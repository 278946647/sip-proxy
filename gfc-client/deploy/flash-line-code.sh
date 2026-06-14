#!/usr/bin/env bash
set -euo pipefail
GFC_ENV="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
[[ -f "$GFC_ENV" ]] && set -a && source "$GFC_ENV" && set +a
FILE=""
CODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) FILE="$2"; shift 2 ;;
    *) CODE="$1"; shift ;;
  esac
done
if [[ -n "$FILE" && -f "$FILE" ]]; then
  CODE=$(tr -d '\n\r ' < "$FILE")
fi
if [[ -z "$CODE" ]]; then
  echo "Usage: flash-line-code.sh <base32-code> | flash-line-code.sh --file /path/to/code.b32"
  exit 1
fi
curl -fsS -X POST "http://127.0.0.1:${GFC_CLIENT_FLASH_PORT:-80}/api/v1/activation/flash" \
  -H 'Content-Type: application/json' \
  -d "{\"code\":\"$CODE\",\"reset_state\":true}"
echo
