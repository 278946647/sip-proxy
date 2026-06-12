#!/usr/bin/env bash
# Legacy: flash is served by gfc-client-web (--mode both). Keep unit for compatibility.
if ss -lnt 2>/dev/null | grep -q ':81 '; then
  echo "port 81 already served by gfc-client-web (both mode)" >&2
  exec sleep infinity
fi
exec /usr/local/bin/gfc-client-web-start
