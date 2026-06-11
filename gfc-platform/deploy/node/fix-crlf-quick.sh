#!/bin/bash
# One-liner-safe CRLF fix. Run: bash deploy/node/fix-crlf-quick.sh [ROOT]
_self="${BASH_SOURCE[0]:-$0}"
python3 - "$_self" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_bytes().decode("utf-8", errors="replace")
f = t.replace("\r\n", "\n").replace("\r", "\n")
if pathlib.Path(sys.argv[1]).suffix == ".sh":
    f = f.replace("pipefail" + "STATE=", "pipefail\nSTATE=")
if f != t:
    p.write_text(f, encoding="utf-8", newline="\n")
    sys.exit(1)
sys.exit(0)
PY
if [[ $? -eq 1 ]]; then exec bash "$_self" "$@"; fi
ROOT="${1:-/var/socks}"
find "$ROOT" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.nft' -o -name 'gfc.env' -o -name 'node.env' \) 2>/dev/null \
  | while IFS= read -r f; do
      python3 - "$f" <<'PY' || true
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_bytes().decode("utf-8", errors="replace")
f = t.replace("\r\n", "\n").replace("\r", "\n")
if pathlib.Path(sys.argv[1]).suffix == ".sh":
    f = f.replace("pipefail" + "STATE=", "pipefail\nSTATE=")
if f != t:
    p.write_text(f, encoding="utf-8", newline="\n")
PY
    done
echo "Fixed CRLF under $ROOT"
