#!/bin/bash
# Fix Windows CRLF in shell scripts (run once on Linux server)
_self="${BASH_SOURCE[0]:-$0}"
python3 - "$_self" <<'PY'
import pathlib
import sys

def fix(path: pathlib.Path) -> bool:
    text = path.read_bytes().decode("utf-8", errors="replace")
    fixed = text.replace("\r\n", "\n").replace("\r", "\n")
    if path.suffix == ".sh":
        fixed = fixed.replace("pipefail" + "STATE=", "pipefail\nSTATE=")
    if fixed != text:
        path.write_text(fixed, encoding="utf-8", newline="\n")
        return True
    return False

if fix(pathlib.Path(sys.argv[1])):
    sys.exit(1)
sys.exit(0)
PY
if [[ $? -eq 1 ]]; then exec bash "$_self" "$@"; fi

ROOT="${1:-/var/socks}"
echo "==> Fix CRLF under $ROOT"
find "$ROOT" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.nft' -o -name '*.env' \) 2>/dev/null \
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
chmod +x "$ROOT/scripts/start-all.sh" 2>/dev/null || true
chmod +x "$ROOT/scripts/fix-crlf.sh" 2>/dev/null || true
chmod +x "$ROOT/scripts/check-prereq.sh" 2>/dev/null || true
chmod +x "$ROOT/deploy/node/install-ubuntu.sh" 2>/dev/null || true
chmod +x "$ROOT/deploy/node/setup-after-copy.sh" 2>/dev/null || true
chmod +x "$ROOT/deploy/node/verify-node.sh" 2>/dev/null || true
chmod +x "$ROOT/deploy/node/run-manual-debug.sh" 2>/dev/null || true
chmod +x "$ROOT/deploy/node/repair-install.sh" 2>/dev/null || true
chmod +x "$ROOT/deploy/node/force-reapply.sh" 2>/dev/null || true
chmod +x "$ROOT/deploy/node/repair-forward-node.sh" 2>/dev/null || true
chmod +x "$ROOT/deploy/node/reinstall-singbox.sh" 2>/dev/null || true
chmod +x "$ROOT/deploy/node/_common.sh" 2>/dev/null || true
chmod +x "$ROOT/deploy/node/fix-crlf-quick.sh" 2>/dev/null || true
chmod +x "$ROOT/deploy/node/repair_forward_node.py" 2>/dev/null || true
chmod +x "$ROOT/deploy/node/_repair_impl.py" 2>/dev/null || true
chmod +x "$ROOT/deploy/node/crlf_util.py" 2>/dev/null || true
chmod +x "$ROOT/deploy/node/install.sh" 2>/dev/null || true
chmod +x "$ROOT/deploy/node/reconfigure-node.sh" 2>/dev/null || true
chmod +x "$ROOT/deploy/node/gfc-node-agent-start.sh" 2>/dev/null || true
chmod +x "$ROOT/deploy/node/fix-node-crlf.py" 2>/dev/null || true
chmod +x "$ROOT/deploy/vm/run-node-agent.sh" 2>/dev/null || true
echo "Fixed CRLF under $ROOT"
