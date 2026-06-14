#!/usr/bin/env bash
# Re-apply mosdns + sing-box from local config bundle
set -euo pipefail

API="${GFC_API_URL:-http://127.0.0.1/api/v1}"

echo "==> reload dataplane"
curl -fsS -X POST "${API}/dataplane/reload"
echo
systemctl restart gfc-mosdns gfc-sing-box
systemctl is-active gfc-mosdns gfc-sing-box gfc-agent
