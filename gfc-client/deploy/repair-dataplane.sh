#!/usr/bin/env bash
# Re-apply mosdns + sing-box from local config bundle
set -euo pipefail

API="${GFC_API_URL:-http://127.0.0.1/api/v1}"

echo "==> reload dataplane"
curl -fsS -X POST "${API}/dataplane/reload"
echo
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$SCRIPT_DIR/start-services.sh"
