#!/usr/bin/env bash
# Control plane one-shot install on Ubuntu 20.04+ (Docker + docker-compose).
#
# 交互安装（推荐）:
#   cd /opt/sip-proxy/gfc-platform && sudo bash deploy/control/install-docker.sh
#
# 非交互:
#   sudo bash deploy/control/install-docker.sh --config deploy/control/install.env --yes
#
# 自动 clone:
#   sudo bash deploy/control/install-docker.sh --clone https://github.com/278946647/sip-proxy.git /opt/sip-proxy/gfc-platform
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=deploy/control/install-config.sh
source "$_SCRIPT_DIR/install-config.sh"
# shellcheck source=deploy/control/compose-util.sh
source "$_SCRIPT_DIR/compose-util.sh"

CLONE_URL=""
CLONE_DIR=""
CONFIG_FILE=""
NON_INTERACTIVE=0

usage() {
  cat <<'EOF'
用法:
  sudo bash deploy/control/install-docker.sh
  sudo bash deploy/control/install-docker.sh --config deploy/control/install.env
  sudo bash deploy/control/install-docker.sh --clone URL [DIR] [--yes]

选项:
  --clone URL [DIR]   安装前 clone/pull 仓库（默认 DIR=当前 gfc-platform 目录）
  --config FILE       从 install.env 读取参数
  --yes               非交互（须 --config 或已 export 环境变量）
  -h, --help          显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clone)
      CLONE_URL=${2:-}
      CLONE_DIR=${3:-}
      shift
      [[ $# -gt 0 && "$1" != --* ]] && shift
      [[ $# -gt 0 && "$1" != --* ]] && shift
      ;;
    --config) CONFIG_FILE=${2:-}; shift 2 ;;
    --yes) NON_INTERACTIVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 执行: sudo bash $0"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl ca-certificates docker.io docker-compose
apt-get install -y -qq docker-compose-plugin 2>/dev/null || true

systemctl enable --now docker

REPO_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"

if [[ -n "$CLONE_URL" ]]; then
  local_dir=${CLONE_DIR:-$REPO_ROOT}
  parent=$(dirname "$local_dir")
  mkdir -p "$parent"
  if [[ -d "$local_dir/.git" ]]; then
    echo "==> git pull $local_dir"
    git -C "$local_dir" pull --ff-only
  else
    echo "==> git clone $CLONE_URL -> $local_dir"
    git clone "$CLONE_URL" "$local_dir"
  fi
  REPO_ROOT="$local_dir"
fi

if [[ ! -f "$REPO_ROOT/docker-compose.yml" ]]; then
  echo "ERROR: 未找到 $REPO_ROOT/docker-compose.yml"
  exit 1
fi

cd "$REPO_ROOT"

echo "==> GFC 控制平台一键安装 (Ubuntu 20.04+)"
echo "    仓库: $REPO_ROOT"

if [[ -n "$CONFIG_FILE" ]]; then
  gfc_cp_load_install_env_file "$CONFIG_FILE" || {
    echo "ERROR: 无法加载 $CONFIG_FILE"
    exit 1
  }
elif [[ -f deploy/control/install.env && $NON_INTERACTIVE -eq 0 && -t 0 ]]; then
  read -r -p "检测到 deploy/control/install.env，是否复用？[y/N]: " reuse
  if [[ "$reuse" =~ ^[Yy]$ ]]; then
    gfc_cp_load_install_env_file deploy/control/install.env
  else
    gfc_cp_collect_install_config_interactive
  fi
elif [[ -n "${GFC_PUBLIC_URL:-}" || -n "${CONTROL_PLANE_HOST:-}" ]]; then
  if [[ -z "${GFC_PUBLIC_URL:-}" && -n "${CONTROL_PLANE_HOST:-}" ]]; then
    GFC_PUBLIC_URL=$(gfc_cp_normalize_url "$CONTROL_PLANE_HOST" "${API_PORT:-8080}")
    export GFC_PUBLIC_URL
  fi
else
  if [[ $NON_INTERACTIVE -eq 1 ]]; then
    echo "ERROR: 非交互模式需要 --config 或环境变量 GFC_PUBLIC_URL / CONTROL_PLANE_HOST"
    exit 1
  fi
  gfc_cp_collect_install_config_interactive
fi

gfc_cp_show_install_summary
gfc_cp_validate_install_config || true

if [[ $NON_INTERACTIVE -eq 0 && -t 0 ]]; then
  read -r -p "确认开始安装？[Y/n]: " ok
  if [[ -n "$ok" && ! "$ok" =~ ^[Yy]$ ]]; then
    echo "已取消"
    exit 0
  fi
fi

gfc_cp_write_env_file "$REPO_ROOT/.env" "$REPO_ROOT/deploy/control/install.env"

install -m 755 "$REPO_ROOT/deploy/control/gfc-compose.sh" /usr/local/bin/gfc-compose

cd "$REPO_ROOT"
echo "==> Building and starting control plane (gfc-compose safe up)..."
gfc_compose_safe_up "$REPO_ROOT" 1
gfc_compose_wait_api "${GFC_PUBLIC_PORT:-8080}" 30 || true

echo ""
echo "==> Done"
gfc_compose_cmd
"${COMPOSE[@]}" ps
echo ""
local_ip=$(gfc_cp_default_ip)
echo "API:  ${GFC_PUBLIC_URL}/healthz"
echo "      http://${local_ip}:${GFC_PUBLIC_PORT:-8080}/healthz （本机）"
echo "Web:  http://${local_ip}:5173"
echo ""
echo "Verify:"
echo "  curl -fsS http://127.0.0.1:${GFC_PUBLIC_PORT:-8080}/healthz"
echo ""
echo "==> 初始管理员账号（首次安装）"
echo "  用户名: admin"
echo "  初始密码: admin123（登录页亦会显示，登录后须立即修改）"
echo "  Bootstrap Token: gfc-compose logs api 2>&1 | grep 'GFC] Security'"
echo ""
echo "日常运维请用 gfc-compose（勿直接用 docker-compose up 替换容器）:"
echo "  gfc-compose up -d          # 全栈"
echo "  gfc-compose up -d web      # 仅 Web"
echo "  sudo bash deploy/control/redeploy-web.sh"
