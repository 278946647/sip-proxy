#!/usr/bin/env bash
# Admin API base URL (gfc-web listener, not flash :80).

gfc_admin_api_url() {
  local env="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
  local port="${GFC_CLIENT_WEB_PORT:-8080}"
  if [[ -f "$env" ]]; then
    # shellcheck disable=SC1090
    source "$env" 2>/dev/null || true
    port="${GFC_CLIENT_WEB_PORT:-8080}"
  fi
  printf 'http://127.0.0.1:%s/api/v1' "$port"
}
