#!/usr/bin/env bash
# Refresh Unbound config from control-plane bundle and reload DNS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-api-url.sh
source "$SCRIPT_DIR/lib-api-url.sh"

API="$(gfc_api_base)/api/v1"
echo "==> unbound config update"
curl -fsS -X POST "${API}/dns/unbound/update" | head -c 400
echo
