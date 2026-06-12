#!/usr/bin/env bash
# One-shot: fix DNS -> git pull -> sync -> repair dataplane -> flash line code
set -euo pipefail

_self="${BASH_SOURCE[0]:-$0}"
_DIR="$(cd "$(dirname "$_self")" && pwd)"
CLIENT_ROOT="$(cd "$_DIR/.." && pwd)"
SRC_ROOT="${SRC_ROOT:-/opt/sip-proxy-src}"

if [[ $EUID -ne 0 ]]; then
  echo "Run: sudo bash $0 [LINE_CODE]"
  exit 1
fi

LINE_CODE=""
if [[ $# -ge 1 ]]; then
  LINE_CODE="$1"
elif [[ -f /etc/gfc-client/activation.b32 ]]; then
  LINE_CODE="$(tr -d '\n\r ' </etc/gfc-client/activation.b32)"
  echo "==> Using saved activation.b32"
else
  echo "Usage: sudo bash $0 LINE_CODE"
  echo "   or: save code to /etc/gfc-client/activation.b32 first"
  exit 1
fi

echo "======== fix DNS + sync + flash ========"
bash "$_DIR/bootstrap-dns.sh"

if [[ -d "$SRC_ROOT/.git" ]]; then
  echo "==> git pull $SRC_ROOT"
  git -C "$SRC_ROOT" pull origin main
  CLIENT_ROOT="$SRC_ROOT/client-agent"
fi

cd "$CLIENT_ROOT"
bash deploy/sync-code.sh
bash deploy/fix-mosdns-unit.sh
systemctl stop gfc-client-agent 2>/dev/null || true
bash deploy/repair-dns.sh

echo "==> Flash + activate"
bash deploy/flash-line-code.sh "$LINE_CODE"

echo ""
echo "======== Done ========"
getent hosts github.com 2>/dev/null && echo "DNS: github.com OK" || echo "DNS: check manually"
systemctl is-active gfc-mosdns gfc-client-sing-box gfc-client-agent 2>/dev/null || true
[[ -f /etc/gfc-client/dataplane-mode.json ]] && cat /etc/gfc-client/dataplane-mode.json
