#!/bin/bash
# Shared helpers for forward-node deploy scripts (source, do not execute).

gfc_fix_crlf_file() {
  local f=$1
  [[ -f "$f" ]] || return 0
  python3 - "$f" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
raw = path.read_bytes()
text = raw.decode("utf-8", errors="replace")
fixed = text.replace("\r\n", "\n").replace("\r", "\n")
if path.suffix == ".sh":
    fixed = fixed.replace("pipefail" + "STATE=", "pipefail\nSTATE=")
if fixed != text:
    path.write_text(fixed, encoding="utf-8", newline="\n")
    sys.exit(1)
sys.exit(0)
PY
}

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
from node_agent.socks_health import evaluate_socks_dns_health

bundle = Path(os.environ["BUNDLE"])
out = Path(os.environ["OUT"])
data = json.loads(bundle.read_text(encoding="utf-8"))
dp = data.get("dataplane") or {}
socks_ok = evaluate_socks_dns_health(data, bundle.parent)
cfg = render_singbox_config(dp, socks_dns_ok=socks_ok)
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
