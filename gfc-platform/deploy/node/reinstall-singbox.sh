#!/bin/bash
# Reinstall sing-box on forward node (default 1.13.4; set SINGBOX_VERSION=latest to override).
_self="${BASH_SOURCE[0]:-$0}"
python3 - "$_self" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_bytes().decode("utf-8", errors="replace")
f = t.replace("\r\n", "\n").replace("\r", "\n")
if p.suffix == ".sh":
    f = f.replace("pipefail" + "STATE=", "pipefail\nSTATE=")
if f != t:
    p.write_text(f, encoding="utf-8", newline="\n")
    sys.exit(1)
sys.exit(0)
PY
if [[ $? -eq 1 ]]; then exec bash "$_self" "$@"; fi
_COMMON="$(cd "$(dirname "$_self")" && pwd)/_common.sh"
if [[ -f "$_COMMON" ]]; then
  # shellcheck source=deploy/node/_common.sh
  source "$_COMMON"
else
  gfc_render_singbox_from_bundle() {
    local gfc_root=${1:-/opt/gfc-node}
    local venv_py="${gfc_root}/node-agent/.venv/bin/python"
    local bundle="${gfc_root}/node-agent/state/dataplane/config_bundle.json"
    [[ -f "$bundle" && -x "$venv_py" ]] || return 1
    GFC_ROOT="$gfc_root" BUNDLE="$bundle" OUT="/etc/gfc-node/sing-box.json" "$venv_py" - <<'PY'
import json, os, sys
from pathlib import Path
sys.path.insert(0, f"{os.environ['GFC_ROOT']}/node-agent")
from node_agent.singbox import render_singbox_config
d = json.loads(Path(os.environ["BUNDLE"]).read_text(encoding="utf-8"))
Path(os.environ["OUT"]).write_text(json.dumps(render_singbox_config(d.get("dataplane") or {}), indent=2), encoding="utf-8")
print("    OK wrote", os.environ["OUT"])
PY
  }
fi
set -euo pipefail

SINGBOX_VERSION="${SINGBOX_VERSION:-1.13.4}"
GFC_ROOT="${GFC_ROOT:-/opt/gfc-node}"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) SB_ARCH=amd64 ;;
  aarch64) SB_ARCH=arm64 ;;
  *) echo "Unsupported arch $ARCH"; exit 1 ;;
esac

if [[ "$SINGBOX_VERSION" == "latest" ]]; then
  URL=$(python3 - <<'PY' "$SB_ARCH"
import json, sys, urllib.request
arch = sys.argv[1]
req = urllib.request.Request(
    "https://api.github.com/repos/SagerNet/sing-box/releases/latest",
    headers={"Accept": "application/vnd.github+json", "User-Agent": "gfc-installer"},
)
with urllib.request.urlopen(req, timeout=60) as r:
    data = json.load(r)
ver = data["tag_name"].lstrip("v")
name = f"sing-box-{ver}-linux-{arch}.tar.gz"
for a in data.get("assets", []):
    if a.get("name") == name:
        print(a["browser_download_url"])
        break
else:
    raise SystemExit(f"asset not found: {name}")
PY
)
else
  URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${SB_ARCH}.tar.gz"
fi

systemctl stop gfc-sing-box 2>/dev/null || true

echo "==> Download $URL"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP/sb.tgz"
tar -xzf "$TMP/sb.tgz" -C "$TMP"
install -m 755 "$(find "$TMP" -name sing-box -type f | head -1)" /usr/local/bin/sing-box.new
mv -f /usr/local/bin/sing-box.new /usr/local/bin/sing-box
echo "==> $(sing-box version | head -1)"

gfc_render_singbox_from_bundle "$GFC_ROOT" || true

if sing-box check -c /etc/gfc-node/sing-box.json; then
  echo "sing-box config OK"
else
  echo "sing-box check FAILED"
  exit 1
fi
systemctl enable gfc-sing-box 2>/dev/null || true
systemctl restart gfc-sing-box
sleep 2
systemctl status gfc-sing-box --no-pager | head -10
