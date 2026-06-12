#!/usr/bin/env bash
# Rebuild and replace ONLY the web container (avoids docker-compose 1.29 ContainerConfig bug on api).
#
# Usage:
#   cd /opt/gfc && sudo bash deploy/control/redeploy-web.sh
set -euo pipefail

ROOT="${GFC_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"

# shellcheck source=deploy/control/compose-util.sh
source "$(dirname "$0")/compose-util.sh"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

gfc_compose_cmd
PROJECT=$(gfc_compose_project_name "$ROOT")
WEB_NAME="${PROJECT}_web_1"

echo "==> sync code from origin/main"
git fetch origin
if ! git rev-parse --verify origin/main >/dev/null 2>&1; then
  echo "ERROR: origin/main not found. Run: git remote -v && git fetch origin"
  exit 1
fi
if [[ "$(git symbolic-ref -q HEAD || true)" != "refs/heads/main" ]]; then
  echo "    checkout main (was detached or other branch)"
  git checkout -B main origin/main
else
  git pull --ff-only origin main
fi
if ! grep -q '安全设置界面 v2' web-ui/src/pages/SettingsPage.tsx 2>/dev/null; then
  echo "ERROR: source tree missing security UI v2 — not on latest main?"
  exit 1
fi

echo "==> build web (no cache)"
"${COMPOSE[@]}" build --no-cache web

echo "==> remove old web container"
docker stop "$WEB_NAME" 2>/dev/null || true
docker rm "$WEB_NAME" 2>/dev/null || true
docker rm -f gfc_web_1 "${PROJECT}_web_1" 2>/dev/null || true

echo "==> start web only (--no-deps, do not touch api)"
"${COMPOSE[@]}" up -d --no-deps web

echo "==> wait for nginx"
sleep 2

echo "==> verify new UI bundle in container"
if docker exec "$WEB_NAME" sh -c "grep -rq '安全设置界面 v2' /usr/share/nginx/html/assets/ 2>/dev/null"; then
  echo "OK: security settings UI v2 is in the running web image"
else
  echo "ERROR: bundle missing '安全设置界面 v2' — build did not include latest SettingsPage.tsx"
  echo "       Check: grep -n '安全设置界面 v2' web-ui/src/pages/SettingsPage.tsx"
  exit 1
fi

echo ""
docker ps --filter name=gfc_ --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "Open Web UI and hard-refresh (Ctrl+Shift+R):"
echo "  平台安全 → 应看到蓝色「敏感项已锁定」+ 灰色虚线只读框 + 底部「安全设置界面 v2」"
