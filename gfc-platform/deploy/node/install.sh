#!/usr/bin/env bash
# GFC 转发节点一键安装（Ubuntu 20.04+，交互式或配置文件）
#
# 交互安装（推荐）:
#   cd /var/socks && sudo bash deploy/node/install.sh
#
# 非交互（提前写好 install.env）:
#   sudo bash deploy/node/install.sh --config deploy/node/install.env
#
# 环境变量方式（兼容旧用法）:
#   sudo SERVER_URL=http://1.2.3.4:8080 GFC_TPROXY_IFACE=ens224 bash deploy/node/install.sh --yes
#
# Windows 拷贝后若报 $'\r' 错误，先: sudo python3 deploy/node/fix-node-crlf.py
_self="${BASH_SOURCE[0]:-$0}"
_self="${_self//$'\r'/}"
_DIR="$(cd "$(dirname "$_self")" && pwd)"

if command -v python3 >/dev/null 2>&1; then
  python3 - "$_DIR" <<'PY'
import pathlib, sys
d = pathlib.Path(sys.argv[1])
changed = False
for p in sorted(d.glob("*.sh")):
    t = p.read_bytes().decode("utf-8", errors="replace")
    f = t.replace("\r\n", "\n").replace("\r", "\n")
    if p.suffix == ".sh":
        f = f.replace("pipefail" + "STATE=", "pipefail\nSTATE=")
    if f != t:
        p.write_text(f, encoding="utf-8", newline="\n")
        changed = True
sys.exit(1 if changed else 0)
PY
  if [[ $? -eq 1 ]]; then
    exec bash "$_DIR/$(basename "$_self")" "$@"
  fi
fi

_REPO="$(cd "$_DIR/../.." && pwd)"
set -euo pipefail

# shellcheck source=deploy/node/install-config.sh
source "$_DIR/install-config.sh"

CONFIG_FILE=""
NON_INTERACTIVE=0
SKIP_VERIFY=0

usage() {
  cat <<'EOF'
用法:
  sudo bash deploy/node/install.sh                    # 交互式填写参数
  sudo bash deploy/node/install.sh --config FILE      # 从 install.env 读取
  sudo bash deploy/node/install.sh --yes              # 非交互（须已 export 或 --config）

选项:
  --config FILE   安装参数文件（见 install.env.example）
  --yes           跳过确认提示
  --skip-verify   安装后不运行 verify-node.sh
  -h, --help      显示帮助

安装后配置:
  /etc/gfc-node/gfc.env      运行参数（改后 systemctl restart gfc-node-agent）
  /etc/gfc-node/install.env  安装时参数备份
  sudo bash deploy/node/reconfigure-node.sh  重新配置已安装节点
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE=${2:-}; shift 2 ;;
    --yes) NON_INTERACTIVE=1; shift ;;
    --skip-verify) SKIP_VERIFY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 执行: sudo bash $0"
  exit 1
fi

if [[ ! -d "$_REPO/node-agent" ]]; then
  echo "ERROR: 未找到 $_REPO/node-agent"
  echo "       请将完整仓库拷到本机（如 /var/socks），在仓库根目录执行本脚本。"
  exit 1
fi

echo "==> GFC 转发节点一键安装 (Ubuntu 20.04+)"
echo "    仓库: $_REPO"

if [[ -n "$CONFIG_FILE" ]]; then
  gfc_load_install_env_file "$CONFIG_FILE" || {
    echo "ERROR: 无法加载 $CONFIG_FILE"
    exit 1
  }
elif [[ -f /etc/gfc-node/install.env && $NON_INTERACTIVE -eq 0 && -t 0 ]]; then
  read -r -p "检测到已有 /etc/gfc-node/install.env，是否复用？[y/N]: " reuse
  if [[ "$reuse" =~ ^[Yy]$ ]]; then
    gfc_load_install_env_file /etc/gfc-node/install.env
  else
    gfc_collect_install_config_interactive
  fi
elif [[ -n "${SERVER_URL:-}" || -n "${CONTROL_PLANE_IP:-}" ]]; then
  gfc_build_server_url || true
  export BOOTSTRAP_TOKEN="${BOOTSTRAP_TOKEN:-demo-bootstrap}"
  export NODE_NAME="${NODE_NAME:-$(hostname -s)}"
  export REGION="${REGION:-ap-southeast-1}"
  export GFC_TPROXY_IFACE="${GFC_TPROXY_IFACE:-}"
  export GFC_ROOT="${GFC_ROOT:-/opt/gfc-node}"
else
  if [[ $NON_INTERACTIVE -eq 1 ]]; then
    echo "ERROR: 非交互模式需要 --config 或环境变量 SERVER_URL / CONTROL_PLANE_IP"
    exit 1
  fi
  gfc_collect_install_config_interactive
fi

gfc_show_install_summary
gfc_validate_install_config || {
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

export REPO_SRC="$_REPO"
export GFC_ROOT="${GFC_ROOT:-/opt/gfc-node}"

# 先写入配置，install-ubuntu.sh 会再次同步 gfc.env（内容一致）
gfc_write_install_files

bash "$_DIR/install-ubuntu.sh"

if [[ $SKIP_VERIFY -eq 0 && -x "$_DIR/verify-node.sh" ]]; then
  API="$SERVER_URL" NODE_NAME="$NODE_NAME" bash "$_DIR/verify-node.sh" || true
fi

echo ""
echo "==> 安装完成"
echo "    控制台 Web UI: 添加 SOCKS、客户线路，约 ${POLL_SECONDS:-10}s 内下发"
echo "    改参数: sudo bash $_DIR/reconfigure-node.sh"
echo "    修复/升级: sudo python3 $_DIR/repair_forward_node.py"
echo "    日志: journalctl -u gfc-node-agent -f"
