#!/usr/bin/env bash
# GFC client box one-shot install (Ubuntu 22.04+)
#
# 交互安装（推荐）:
#   cd client-agent && sudo bash deploy/flash-line-code.sh /path/to/linecode.b32
#   sudo bash deploy/install.sh
#
# 非交互:
#   sudo bash deploy/install.sh --config deploy/install.env --yes
set -euo pipefail
_self="${BASH_SOURCE[0]:-$0}"
_self="${_self//$'\r'/}"
_DIR="$(cd "$(dirname "$_self")" && pwd)"

if [[ -f "$_DIR/client_agent/__init__.py" ]]; then
  CLIENT_ROOT="$_DIR"
  DEPLOY_DIR="$_DIR/deploy"
elif [[ -f "$_DIR/../client_agent/__init__.py" ]]; then
  CLIENT_ROOT="$(cd "$_DIR/.." && pwd)"
  DEPLOY_DIR="$_DIR"
else
  echo "ERROR: client_agent package not found"
  exit 1
fi

# shellcheck source=deploy/install-config.sh
source "$DEPLOY_DIR/install-config.sh"

CONFIG_FILE=""
NON_INTERACTIVE=0

usage() {
  cat <<'EOF'
用法:
  sudo bash deploy/install.sh
  sudo bash deploy/install.sh --config deploy/install.env
  sudo bash deploy/install.sh --yes

选项:
  --config FILE   安装参数文件（见 install.env.example）
  --yes           非交互
  -h, --help      显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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

echo "==> GFC 客户端盒子一键安装"
echo "    源码: $CLIENT_ROOT"

if [[ -n "$CONFIG_FILE" ]]; then
  gfc_client_load_install_env_file "$CONFIG_FILE" || {
    echo "ERROR: 无法加载 $CONFIG_FILE"
    exit 1
  }
elif [[ -f /etc/gfc-client/install.env && $NON_INTERACTIVE -eq 0 && -t 0 ]]; then
  read -r -p "检测到 /etc/gfc-client/install.env，是否复用？[y/N]: " reuse
  if [[ "$reuse" =~ ^[Yy]$ ]]; then
    gfc_client_load_install_env_file /etc/gfc-client/install.env
  else
    gfc_client_collect_install_config_interactive
  fi
elif [[ -n "${SERVER_URL:-}" || -n "${CONTROL_PLANE_HOST:-}" ]]; then
  if [[ -n "${CONTROL_PLANE_HOST:-}" && -z "${SERVER_URL:-}" ]]; then
    SERVER_URL=$(gfc_client_normalize_url "$CONTROL_PLANE_HOST" "${API_PORT:-8080}")
    export SERVER_URL
  fi
  if [[ -n "${CONTROL_PLANE_HOST_FALLBACK:-}" && -z "${SERVER_URL_FALLBACK:-}" ]]; then
    SERVER_URL_FALLBACK=$(gfc_client_normalize_url "$CONTROL_PLANE_HOST_FALLBACK" "${API_PORT:-8080}")
    export SERVER_URL_FALLBACK
  fi
  export DEVICE_NAME="${DEVICE_NAME:-$(hostname -s)}"
  export GFC_PROXY_MODE="${GFC_PROXY_MODE:-gateway}"
  export ACTIVATION_FILE="${ACTIVATION_FILE:-/etc/gfc-client/activation.b32}"
  export GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
else
  if [[ $NON_INTERACTIVE -eq 1 ]]; then
    echo "ERROR: 非交互模式需要 --config，或已刷线路码（activation.b32）"
    exit 1
  fi
  gfc_client_collect_install_config_interactive
fi

gfc_client_show_install_summary
gfc_client_validate_install_config || {
  if [[ $NON_INTERACTIVE -eq 0 && -t 0 ]]; then
    read -r -p "存在告警，仍继续安装？[y/N]: " cont
    [[ "$cont" =~ ^[Yy]$ ]] || exit 1
  fi
}

if [[ $NON_INTERACTIVE -eq 0 && -t 0 ]]; then
  read -r -p "确认开始安装？[Y/n]: " ok
  if [[ -n "$ok" && ! "$ok" =~ ^[Yy]$ ]]; then
    echo "已取消"
    exit 0
  fi
fi

gfc_client_write_install_env_file /etc/gfc-client/install.env

export CLIENT_ROOT
export SERVER_URL SERVER_URL_FALLBACK DEVICE_NAME GFC_PROXY_MODE GFC_LAN_IFACE GFC_WAN_IFACE
export ACTIVATION_FILE GFC_ROOT POLL_SECONDS

bash "$DEPLOY_DIR/install-ubuntu.sh"
systemctl restart gfc-client-agent 2>/dev/null || true

echo ""
echo "==> 安装完成"
echo "    配置: /etc/gfc-client/gfc.env"
echo "    日志: /var/log/gfc-client/"
echo "    本地 Web: http://127.0.0.1:8787"
