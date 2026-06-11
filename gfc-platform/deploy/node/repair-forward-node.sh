#!/bin/bash
# One-shot forward node repair (bash fallback).
# Prefer: sudo python3 deploy/node/repair_forward_node.py
# Usage: sudo bash deploy/node/repair-forward-node.sh [REPO_ROOT]
_self="${BASH_SOURCE[0]:-$0}"

gfc_fix_crlf_file() {
  local f=$1
  [[ -f "$f" ]] || return 0
  python3 - "$f" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_bytes().decode("utf-8", errors="replace")
fixed = text.replace("\r\n", "\n").replace("\r", "\n")
if path.suffix == ".sh":
    fixed = fixed.replace("pipefail" + "STATE=", "pipefail\nSTATE=")
if fixed != text:
    path.write_text(fixed, encoding="utf-8", newline="\n")
    sys.exit(1)
sys.exit(0)
PY
}

if gfc_fix_crlf_file "$_self"; then exec bash "$_self" "$@"; fi

_PY_REPAIR="$(cd "$(dirname "$_self")" && pwd)/repair_forward_node.py"
if [[ -f "$_PY_REPAIR" && -f "$(dirname "$_PY_REPAIR")/_repair_impl.py" ]]; then
  exec python3 "$_PY_REPAIR"
fi

gfc_fix_crlf_tree() {
  local root=${1:-/var/socks}
  echo "==> Fix CRLF under $root"
  find "$root" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.nft' -o -name '*.env' \) 2>/dev/null \
    | while IFS= read -r f; do gfc_fix_crlf_file "$f" || true; done
}

gfc_render_singbox_from_bundle() {
  local gfc_root=${1:-/opt/gfc-node}
  local venv_py="${gfc_root}/node-agent/.venv/bin/python"
  local bundle="${gfc_root}/node-agent/state/dataplane/config_bundle.json"
  local out="/etc/gfc-node/sing-box.json"
  if [[ ! -f "$bundle" || ! -x "$venv_py" ]]; then
    echo "    WARN cannot render sing-box (missing bundle or venv)"
    return 1
  fi
  echo "==> Render $out from config bundle"
  GFC_ROOT="$gfc_root" BUNDLE="$bundle" OUT="$out" "$venv_py" - <<'PY'
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, f"{os.environ['GFC_ROOT']}/node-agent")
from node_agent.singbox import render_singbox_config

bundle = Path(os.environ["BUNDLE"])
out = Path(os.environ["OUT"])
data = json.loads(bundle.read_text(encoding="utf-8"))
cfg = render_singbox_config(data.get("dataplane") or {})
out.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"    OK wrote {out}")
PY
}

gfc_clear_applied_version() {
  local state=${1:-/opt/gfc-node/node-agent/state/node_state.json}
  python3 - <<PY
import json
p = "${state}"
with open(p, encoding="utf-8") as f:
    d = json.load(f)
d.pop("applied_version", None)
with open(p, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
print("cleared applied_version in", p)
PY
}

set -euo pipefail

REPO_ROOT="${1:-$(cd "$(dirname "$_self")/../.." && pwd)}"
GFC_ROOT="${GFC_ROOT:-/opt/gfc-node}"
SINGBOX_VERSION="${SINGBOX_VERSION:-1.13.4}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

echo "==> GFC forward node repair"
echo "    Repo:    $REPO_ROOT"
echo "    Install: $GFC_ROOT"

gfc_fix_crlf_tree "$REPO_ROOT"

echo "==> Sync node-agent -> $GFC_ROOT/node-agent"
rsync -a --delete "${REPO_ROOT}/node-agent/" "${GFC_ROOT}/node-agent/" \
  --exclude .venv --exclude state

if [[ ! -d "${GFC_ROOT}/node-agent/.venv" ]]; then
  python3 -m venv "${GFC_ROOT}/node-agent/.venv"
fi
"${GFC_ROOT}/node-agent/.venv/bin/pip" install -q -U pip
"${GFC_ROOT}/node-agent/.venv/bin/pip" install -q -r "${GFC_ROOT}/node-agent/requirements.txt"

echo "==> Install sing-box ${SINGBOX_VERSION}"
SINGBOX_VERSION="$SINGBOX_VERSION" bash "$(dirname "$_self")/reinstall-singbox.sh"

gfc_render_singbox_from_bundle "$GFC_ROOT" || true
sing-box check -c /etc/gfc-node/sing-box.json

if [[ -f "${GFC_ROOT}/node-agent/state/node_state.json" ]]; then
  gfc_clear_applied_version "${GFC_ROOT}/node-agent/state/node_state.json"
fi

echo "==> Restart services"
systemctl restart gfc-node-agent
sleep 12
systemctl restart gfc-sing-box
sleep 2

echo "==> Status"
systemctl is-active gfc-node-agent gfc-sing-box
sing-box check -c /etc/gfc-node/sing-box.json && echo "sing-box config OK"
journalctl -u gfc-node-agent -n 8 --no-pager | grep -E 'applied|apply failed|error' || journalctl -u gfc-node-agent -n 5 --no-pager

if [[ -x "${REPO_ROOT}/deploy/node/verify-node.sh" ]]; then
  gfc_fix_crlf_file "${REPO_ROOT}/deploy/node/verify-node.sh" || true
  bash "${REPO_ROOT}/deploy/node/verify-node.sh"
fi

echo "==> Repair done"
