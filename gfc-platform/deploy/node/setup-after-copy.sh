#!/usr/bin/env bash
# Run on the forward node after copying the full repo (e.g. to /var/socks).
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Strip CRLF before "set -o pipefail" (Windows copies break pipefail otherwise).
# shellcheck source=deploy/node/_common.sh
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"
gfc_fix_crlf_tree "$REPO_ROOT"
set -euo pipefail

ENV_FILE="${ENV_FILE:-$REPO_ROOT/deploy/node/install.env}"
LEGACY_ENV="$REPO_ROOT/deploy/node/node.env"

echo "==> GFC setup after copy"
echo "    Repo: $REPO_ROOT"

if [[ $EUID -ne 0 ]]; then
  echo "Re-run as root: sudo bash $0"
  exit 1
fi

echo "==> Fix CRLF (Windows copies)"
if [[ -x "$REPO_ROOT/scripts/fix-crlf.sh" ]]; then
  bash "$REPO_ROOT/scripts/fix-crlf.sh" "$REPO_ROOT"
else
  gfc_fix_crlf_tree "$REPO_ROOT"
fi
chmod +x "$REPO_ROOT/scripts/"*.sh 2>/dev/null || true
chmod +x "$REPO_ROOT/deploy/node/"*.sh 2>/dev/null || true
chmod +x "$REPO_ROOT/deploy/node/install.sh" 2>/dev/null || true

if [[ -f "$ENV_FILE" ]]; then
  echo "==> 使用配置文件 $ENV_FILE 安装"
  exec bash "$REPO_ROOT/deploy/node/install.sh" --config "$ENV_FILE" --yes
fi

if [[ -f "$LEGACY_ENV" ]]; then
  echo "==> 使用旧版 node.env 安装"
  exec bash "$REPO_ROOT/deploy/node/install.sh" --config "$LEGACY_ENV" --yes
fi

if [[ ! -f "$REPO_ROOT/deploy/node/install.env.example" ]]; then
  echo "ERROR: missing deploy/node/install.env.example"
  exit 1
fi

cp "$REPO_ROOT/deploy/node/install.env.example" "$ENV_FILE"
echo "已创建 $ENV_FILE — 请编辑控制平台 IP、NODE_NAME、GFC_TPROXY_IFACE 后执行:"
echo "  sudo bash $REPO_ROOT/deploy/node/install.sh --config $ENV_FILE"
echo ""
echo "或直接交互安装:"
echo "  sudo bash $REPO_ROOT/deploy/node/install.sh"
exit 1
