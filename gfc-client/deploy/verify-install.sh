#!/usr/bin/env bash
# End-to-end smoke test on installed box
set -euo pipefail

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

check "gfc-api binary" "test -x /usr/local/bin/gfc-api"
check "gfc-agent binary" "test -x /usr/local/bin/gfc-agent"
check "sing-box binary" "command -v sing-box"
check "mosdns binary" "command -v mosdns"
check "api :80" "curl -fsS --connect-timeout 2 http://127.0.0.1:80/api/v1/health"
check "flash :81" "curl -fsS --connect-timeout 2 http://127.0.0.1:81/api/v1/health"
check "agent active" "systemctl is-active --quiet gfc-client-agent"
check "rules dir" "test -d /var/lib/gfc-client/rules"
check "sing-box config" "test -f /etc/gfc-client/sing-box.json"

if [[ -f /etc/gfc-client/activation.b32 ]]; then
  echo "INFO activation file present"
else
  echo "INFO no activation yet (idle OK)"
fi

exit $fail
