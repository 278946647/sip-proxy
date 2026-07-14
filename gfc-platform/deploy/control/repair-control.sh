#!/usr/bin/env bash
# One-shot repair: fix docker-compose 1.29 ContainerConfig + restart API/Web.
#
# Usage:
#   cd /opt/sip-proxy/gfc-platform && sudo bash deploy/control/repair-control.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=deploy/control/compose-util.sh
source "$(dirname "$0")/compose-util.sh"

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 执行: sudo bash $0"
  exit 1
fi

gfc_compose_cmd

echo "==> GFC 控制平台修复 (docker-compose 1.29 ContainerConfig)"
echo "    目录: $ROOT"

if [[ -d .git ]]; then
  echo "==> git pull"
  git pull --ff-only origin main 2>/dev/null || git pull --ff-only 2>/dev/null || true
fi

echo "==> 重建 API / Web 镜像"
"${COMPOSE[@]}" build --no-cache api web

echo "==> Reverse SSH host prerequisites"
bash "$ROOT/deploy/control/setup-reverse-ssh.sh"

echo "==> 安全重启（先删容器再 up，避免 ContainerConfig）"
install -m 755 "$ROOT/deploy/control/gfc-compose.sh" /usr/local/bin/gfc-compose 2>/dev/null || true
gfc_compose_safe_up "$ROOT" 0

if ! gfc_compose_wait_api "${GFC_PUBLIC_PORT:-8181}" 30; then
  echo ""
  echo "==> API 未就绪，最近日志:"
  "${COMPOSE[@]}" logs --tail=100 api || true
  exit 1
fi

echo ""
"${COMPOSE[@]}" ps
echo ""
echo "验证:"
echo "  curl -fsS http://127.0.0.1:8181/healthz"
echo "  curl -fsS http://127.0.0.1:5173/"
echo ""
echo "以后请使用: gfc-compose up -d [api|web]  （已安装 /usr/local/bin/gfc-compose）"
echo ""
echo "登录: admin / admin123（首次须改密）"
