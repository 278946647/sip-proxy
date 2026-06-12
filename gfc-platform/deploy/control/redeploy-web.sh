#!/usr/bin/env bash
# Rebuild and replace ONLY the web container (API untouched).
#
# Usage:
#   cd /opt/sip-proxy/gfc-platform && sudo bash deploy/control/redeploy-web.sh
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
install -m 755 "$ROOT/deploy/control/gfc-compose.sh" /usr/local/bin/gfc-compose 2>/dev/null || true
PROJECT=$(gfc_compose_project_name "$ROOT")

if [[ -d .git ]]; then
  echo "==> sync code"
  git fetch origin 2>/dev/null || true
  git pull --ff-only origin main 2>/dev/null || git pull --ff-only 2>/dev/null || true
fi

echo "==> build web (no cache)"
"${COMPOSE[@]}" build --no-cache web

echo "==> safe replace web (gfc_compose_safe_up_service)"
gfc_compose_safe_up_service "$ROOT" web 0

sleep 2
WEB_CID=$(gfc_compose_service_container_id "$ROOT" web)
if [[ -n "$WEB_CID" ]] && docker exec "$WEB_CID" test -f /usr/share/nginx/html/index.html; then
  echo "OK: web container serving static bundle"
else
  echo "ERROR: web container not healthy"
  "${COMPOSE[@]}" logs --tail=30 web 2>/dev/null || true
  exit 1
fi

echo ""
docker ps --filter "label=com.docker.compose.project=${PROJECT}" \
  --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "Open Web UI and hard-refresh (Ctrl+Shift+R)"
