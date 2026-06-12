#!/usr/bin/env bash
# Import easymosdns domain lists into GFC client mosdns tables
set -euo pipefail

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
AGENT_DIR="${AGENT_DIR:-$GFC_ROOT/client-agent}"
BASE="https://raw.githubusercontent.com/pmkol/easymosdns/main"

declare -A MAP=(
  [china]="$BASE/rules/china_domain_list.txt"
  [global]="$BASE/rules/gfw_domain_list.txt"
  [block]="$BASE/rules/ad_domain_list.txt"
)

export PYTHONPATH="$AGENT_DIR"
PY="${AGENT_DIR}/.venv/bin/python"
[[ -x "$PY" ]] || PY="$(command -v python3)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for list in china global block; do
  url="${MAP[$list]}"
  echo "==> Fetch $list from easymosdns"
  curl -fsSL "$url" -o "$tmp/$list.txt"
  n=$("$PY" -c "
from client_agent.dns_lists import import_list_text
from pathlib import Path
text = Path('$tmp/$list.txt').read_text(encoding='utf-8')
print(len(import_list_text('$list', text, replace=True)))
")
  echo "    $list: $n domains"
done

"$PY" -c "from client_agent.apply import apply_dns_config; print(apply_dns_config()[1])"
systemctl restart gfc-mosdns.service
echo "Done."
