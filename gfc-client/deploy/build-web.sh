#!/usr/bin/env bash
# Build Vue3 web UI -> web-static/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=install-node.sh
source "$ROOT/deploy/install-node.sh"
ensure_node

echo "==> Vue3 build"
cd "$ROOT/web"
if [[ -f package-lock.json ]]; then
  npm ci --no-audit --no-fund
else
  npm install --no-audit --no-fund
fi
npm run build

rm -rf "$ROOT/web-static"
cp -a "$ROOT/web/dist" "$ROOT/web-static"
echo "    web-static/"
