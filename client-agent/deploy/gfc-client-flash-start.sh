#!/usr/bin/env bash
# gfc-client-web (--mode both) serves :81; keep this unit active without binding.
set -euo pipefail
ENV_FILE="${ENV_FILE:-/etc/gfc-client/gfc.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

mode="${GFC_WEB_MODE:-both}"
if [[ "$mode" == "both" ]]; then
  echo "flash UI served by gfc-client-web on :81 (GFC_WEB_MODE=both)" >&2
  exec sleep infinity
fi

if ss -lnt 2>/dev/null | grep -q ':81 '; then
  echo "port 81 already in use" >&2
  exec sleep infinity
fi

exec /usr/local/bin/gfc-client-web-start
