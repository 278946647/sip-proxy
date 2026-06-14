#!/usr/bin/env bash
# Re-apply mosdns + sing-box from local config bundle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-api-url.sh
source "$SCRIPT_DIR/lib-api-url.sh"
API="${GFC_API_URL:-$(gfc_admin_api_url)}"

echo "==> reload dataplane (${API})"
curl -fsS -X POST "${API}/dataplane/reload"
echo
bash "$SCRIPT_DIR/start-services.sh"
