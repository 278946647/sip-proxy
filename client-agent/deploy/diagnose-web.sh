#!/usr/bin/env bash
# Diagnose why :80 / :81 Web may be unreachable
set -uo pipefail

echo "======== GFC Web 诊断 (:80 / :81) ========"
echo ""

echo "=== 1. 端口监听 ==="
ss -lntup 2>/dev/null | grep -E '(:80 |:81 |:8787 )' || echo "(80/81/8787 均无监听)"
echo ""

echo "=== 2. systemd 状态 ==="
systemctl is-active gfc-client-web gfc-client-flash 2>/dev/null || true
systemctl status gfc-client-web gfc-client-flash --no-pager -l 2>/dev/null | head -40 || true
echo ""

echo "=== 3. 环境变量 /etc/gfc-client/gfc.env ==="
grep -E 'GFC_CLIENT_WEB|GFC_CLIENT_FLASH|GFC_WEB' /etc/gfc-client/gfc.env 2>/dev/null || echo "(无或文件不存在)"
echo ""

echo "=== 4. 启动脚本 ==="
head -5 /usr/local/bin/gfc-client-web-start 2>/dev/null || echo "MISSING gfc-client-web-start"
echo "..."
tail -3 /usr/local/bin/gfc-client-web-start 2>/dev/null || true
echo ""

echo "=== 5. 关键文件 ==="
for f in \
  /opt/gfc-client/client-web/index.html \
  /opt/gfc-client/client-web/flash.html \
  /opt/gfc-client/client-agent/client_agent/web_server.py \
  /opt/gfc-client/client-agent/.venv/bin/python; do
  [[ -e "$f" ]] && echo "  OK  $f" || echo "  MISS $f"
done
echo ""

echo "=== 6. 本机 curl ==="
for url in http://127.0.0.1/ http://127.0.0.1:81/ http://192.168.68.1/ http://192.168.68.1:81/; do
  code=$(curl -fsS -o /dev/null -w '%{http_code}' --connect-timeout 2 "$url" 2>/dev/null || echo "FAIL")
  echo "  $url -> $code"
done
echo ""

echo "=== 7. 80 端口占用详情（若被占） ==="
ss -lntup | grep ':80 ' || echo "  80 未被监听"
fuser -v 80/tcp 2>/dev/null || true
echo ""

echo "=== 8. 防火墙 ==="
if command -v ufw >/dev/null; then ufw status 2>/dev/null | head -5; fi
nft list chain inet gfc_client_filter input 2>/dev/null | head -15 || echo "  (无 gfc nft input 链)"
echo ""

echo "=== 9. Web 日志 (最近 15 行) ==="
tail -15 /var/log/gfc-client/gfc-client-web.log 2>/dev/null || journalctl -u gfc-client-web -n 15 --no-pager 2>/dev/null || true
echo ""

echo "=== 10. 手动试启 (仅测试，Ctrl+C 结束) ==="
echo "  cd /opt/gfc-client/client-agent"
echo "  .venv/bin/python -m client_agent.web_server --mode both --root /opt/gfc-client/client-web"
echo ""
echo "=== 快速修复 ==="
echo "  cd /opt/sip-proxy-src/client-agent && sudo bash deploy/repair-web.sh"
