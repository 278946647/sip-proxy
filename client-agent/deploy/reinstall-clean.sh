#!/usr/bin/env bash
# Clean reinstall on Ubuntu 22.04 — stop proxy stack, bootstrap DNS, wipe GFC state, install
set -euo pipefail

_self="${BASH_SOURCE[0]:-$0}"
_DIR="$(cd "$(dirname "$_self")" && pwd)"
CLIENT_ROOT="$(cd "$_DIR/.." && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "Run: sudo bash $0"
  exit 1
fi

KEEP_LINE_CODE=0
CONFIG_FILE=""
NON_INTERACTIVE=0

usage() {
  cat <<EOF
用法:
  sudo bash deploy/reinstall-clean.sh
  sudo bash deploy/reinstall-clean.sh --keep-line-code
  sudo bash deploy/reinstall-clean.sh --config deploy/install.env --yes

选项:
  --keep-line-code   保留 /etc/gfc-client/activation.b32
  --config FILE      传给 install.sh
  --yes              非交互安装
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-line-code) KEEP_LINE_CODE=1; shift ;;
    --config) CONFIG_FILE=${2:-}; shift 2 ;;
    --yes) NON_INTERACTIVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 1 ;;
  esac
done

echo "======== GFC 干净重装 ========"

echo "==> 1) 停止 GFC 服务（解除 DNS 劫持）"
for u in gfc-client-sing-box gfc-mosdns gfc-client-agent gfc-client-web gfc-client-flash; do
  systemctl stop "$u" 2>/dev/null || true
  systemctl disable "$u" 2>/dev/null || true
done
systemctl mask gfc-client-flash 2>/dev/null || true
ip link del gfc0 2>/dev/null || true

echo "==> 2) 引导 DNS（直连公网，不经过 mosdns/sing-box）"
if systemctl is-active systemd-resolved &>/dev/null; then
  resolvectl dns 2>/dev/null || true
  mkdir -p /etc/systemd/resolved.conf.d
  cat >/etc/systemd/resolved.conf.d/gfc-bootstrap.conf <<'EOF'
[Resolve]
DNS=223.5.5.5 119.29.29.29
FallbackDNS=8.8.8.8 1.1.1.1
DNSStubListener=no
EOF
  systemctl restart systemd-resolved
fi
rm -f /etc/resolv.conf
cat >/etc/resolv.conf <<'EOF'
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 8.8.8.8
EOF
chmod 644 /etc/resolv.conf

echo "    测试解析:"
if getent hosts github.com >/dev/null 2>&1; then
  echo "    OK github.com"
else
  echo "    WARN: 仍无法解析 github.com — 请确认 WAN 能上网（ping 223.5.5.5）"
  ping -c1 -W2 223.5.5.5 >/dev/null 2>&1 || {
    echo "    ERROR: WAN 不通，请先修复网卡/DHCP 再继续"
    exit 1
  }
fi

LINE_BACKUP=""
if [[ $KEEP_LINE_CODE -eq 1 && -f /etc/gfc-client/activation.b32 ]]; then
  LINE_BACKUP=$(mktemp)
  cp /etc/gfc-client/activation.b32 "$LINE_BACKUP"
  echo "==> 已备份线路码"
fi

echo "==> 3) 清理旧安装"
rm -rf /opt/gfc-client /var/lib/gfc-client /var/log/gfc-client
rm -rf /etc/gfc-client
mkdir -p /etc/gfc-client

if [[ -n "$LINE_BACKUP" ]]; then
  install -m 600 "$LINE_BACKUP" /etc/gfc-client/activation.b32
  rm -f "$LINE_BACKUP"
fi

echo "==> 4) 重新安装"
INSTALL_ARGS=()
[[ -n "$CONFIG_FILE" ]] && INSTALL_ARGS+=(--config "$CONFIG_FILE")
[[ $NON_INTERACTIVE -eq 1 ]] && INSTALL_ARGS+=(--yes)
bash "$CLIENT_ROOT/deploy/install.sh" "${INSTALL_ARGS[@]}"

echo "==> 5) 一键修复（最新脚本）"
if [[ -f "$CLIENT_ROOT/deploy/repair-all.sh" ]]; then
  bash "$CLIENT_ROOT/deploy/repair-all.sh" || true
fi

echo ""
echo "======== 完成 ========"
echo "  管理: http://192.168.68.1/"
echo "  刷码: http://192.168.68.1:81/"
echo "  线路码: /etc/gfc-client/activation.b32"
systemctl is-active gfc-mosdns gfc-client-sing-box gfc-client-web gfc-client-agent 2>/dev/null || true
