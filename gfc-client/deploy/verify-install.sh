#!/usr/bin/env bash
# End-to-end smoke test on installed box
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() {
  local name="$1" cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    echo "OK  $name"
  else
    echo "FAIL $name"
    fail=1
  fi
}

if [[ ! -f /etc/gfc-client/sing-box.json || ! -f /etc/gfc-client/mosdns/easymosdns/config.yaml ]]; then
  echo "==> idle configs missing, running bootstrap"
  sudo bash "$SCRIPT_DIR/bootstrap-idle.sh" || true
fi

check "gfc-api binary" "test -x /usr/local/bin/gfc-api"
check "gfc-agent binary" "test -x /usr/local/bin/gfc-agent"
check "gfc-bootstrap binary" "test -x /usr/local/bin/gfc-bootstrap"
check "sing-box binary" "command -v sing-box"
check "mosdns binary" "command -v mosdns"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GFC_ENV="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
[[ -f "$GFC_ENV" ]] && set -a && source "$GFC_ENV" && set +a
FLASH_PORT="${GFC_CLIENT_FLASH_PORT:-80}"
WEB_PORT="${GFC_CLIENT_WEB_PORT:-8080}"

check "api :${WEB_PORT}" "curl -fsS --connect-timeout 2 http://127.0.0.1:${WEB_PORT}/api/v1/health"
check "flash :${FLASH_PORT}" "curl -fsS --connect-timeout 2 http://127.0.0.1:${FLASH_PORT}/api/v1/health"
check "network active" "systemctl is-active --quiet gfc-network"
check "agent active" "systemctl is-active --quiet gfc-agent"
check "web active" "systemctl is-active --quiet gfc-web"
check "mosdns active" "systemctl is-active --quiet gfc-mosdns"
check "mosdns uid 65353" "test \"$(id -u mosdns 2>/dev/null)\" = \"65353\""
check "sing-box active" "systemctl is-active --quiet gfc-sing-box"
check "sing-box uid 65354" "test \"$(id -u singbox 2>/dev/null)\" = \"65354\""
GFC_ENV="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
[[ -f "$GFC_ENV" ]] && set -a && source "$GFC_ENV" && set +a
if [[ "${GFC_PROXY_MODE:-gateway}" != "bypass" ]]; then
  check "routing active" "systemctl is-active --quiet gfc-routing"
  check "policy ip rule" "ip -4 rule list | grep -qE 'fwmark .*lookup 2022'"
  check "policy table gfctun" "ip -4 route show table 2022 | grep -qE 'default (dev|via) gfctun'"
  check "nft mangle mark" "test -f /etc/gfc-client/nftables-policy.conf"
  check "scheme B kernel-split" "grep -qE 'Scheme B|kernel-split|chain classify' /etc/gfc-client/nftables-policy.conf"
  check "nft cn_ip set" "grep -q 'set cn_ip' /etc/gfc-client/nftables-policy.conf"
  check "nft cn_ip load" "test -f /etc/gfc-client/nftables-cn-ip-load.nft"
  check "nft bypass set" "grep -q 'set bypass_ip' /etc/gfc-client/nftables-policy.conf"
  check "nft sing-box uid exempt" "grep -q 'meta skuid 65354' /etc/gfc-client/nftables-policy.conf"
  check "nft mosdns doh mark" "grep -q 'meta skuid 65353.*443' /etc/gfc-client/nftables-policy.conf"
  check "sing-box no auto_route" "! grep -qE '\"auto_route\":\\s*true' /etc/gfc-client/sing-box.json"
  check "sing-box no geo rule_set" "! grep -q 'rule_set' /etc/gfc-client/sing-box.json"
  check "sing-box runs as singbox" "ps -o user= -C sing-box 2>/dev/null | grep -qx singbox"
  check "sing-box config group" "test \"$(stat -c '%G' /etc/gfc-client/sing-box.json 2>/dev/null)\" = \"singbox\""
fi
check "rules dir" "test -d /var/lib/gfc-client/rules"
check "mosdns config" "test -f /etc/gfc-client/mosdns/easymosdns/config.yaml"
check "sing-box config" "test -f /etc/gfc-client/sing-box.json"
check "resolv.conf 127.0.0.1" "grep -q 'nameserver 127.0.0.1' /etc/resolv.conf"
check "resolved stopped" "! systemctl is-active --quiet systemd-resolved"
check "mosdns listens :53" "grep -qE 'addr: \"0\\.0\\.0\\.0:53\"' /etc/gfc-client/mosdns/easymosdns/config.yaml"
check "nftables dns hijack" "test -f /etc/gfc-client/nftables-dns.conf"
check "nft excludes mosdns uid" "grep -q 'meta skuid != 65353' /etc/gfc-client/nftables-dns.conf"

if [[ -f /etc/gfc-client/activation.b32 ]]; then
  echo "INFO activation file present"
else
  echo "INFO no activation yet (idle OK)"
fi

exit $fail
