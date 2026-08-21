#!/usr/bin/env bash
# Unbound system identity + OUTPUT DNS hijack (skuid-based, fixed uid).
GFC_UNBOUND_UID="${GFC_UNBOUND_UID:-${GFC_MOSDNS_UID:-65353}}"
GFC_UNBOUND_USER="${GFC_UNBOUND_USER:-unbound}"
# Backward-compatible aliases for legacy deploy scripts.
GFC_MOSDNS_UID="${GFC_UNBOUND_UID}"
GFC_MOSDNS_USER="${GFC_UNBOUND_USER}"

ensure_unbound_user() {
  if ! getent group "$GFC_UNBOUND_USER" >/dev/null; then
    groupadd -r "$GFC_UNBOUND_USER"
  fi
  if id -u "$GFC_UNBOUND_USER" &>/dev/null; then
    return 0
  fi
  if getent passwd "$GFC_UNBOUND_UID" >/dev/null; then
    echo "ERROR: uid ${GFC_UNBOUND_UID} already used by $(getent passwd "$GFC_UNBOUND_UID" | cut -d: -f1)" >&2
    return 1
  fi
  useradd -r -u "$GFC_UNBOUND_UID" -g "$GFC_UNBOUND_USER" -s /usr/sbin/nologin \
    -d /var/lib/unbound -M "$GFC_UNBOUND_USER"
}

migrate_unbound_user() {
  if ! getent group "$GFC_UNBOUND_USER" >/dev/null; then
    groupadd -r "$GFC_UNBOUND_USER"
  fi
  if id -u "$GFC_UNBOUND_USER" &>/dev/null; then
    local uid
    uid="$(id -u "$GFC_UNBOUND_USER")"
    if [[ "$uid" == "$GFC_UNBOUND_UID" ]]; then
      return 0
    fi
    echo "    migrate ${GFC_UNBOUND_USER} uid ${uid} -> ${GFC_UNBOUND_UID}"
    systemctl stop gfc-unbound.service gfc-mosdns.service 2>/dev/null || true
    userdel "$GFC_UNBOUND_USER" 2>/dev/null || true
  fi
  if getent passwd "$GFC_UNBOUND_UID" >/dev/null; then
    local owner
    owner="$(getent passwd "$GFC_UNBOUND_UID" | cut -d: -f1)"
    if [[ "$owner" == "$GFC_UNBOUND_USER" ]]; then
      return 0
    fi
    echo "ERROR: uid ${GFC_UNBOUND_UID} already used by ${owner}" >&2
    return 1
  fi
  useradd -r -u "$GFC_UNBOUND_UID" -g "$GFC_UNBOUND_USER" -s /usr/sbin/nologin \
    -d /var/lib/unbound -M "$GFC_UNBOUND_USER"
}

write_gfc_nft_dns_conf() {
  local lan="$1" port="$2" outfile="$3"
  local wan="${WAN:-${GFC_WAN_IFACE:-}}"
  local mode="${GFC_PROXY_MODE:-gateway}"
  local hosts_file="${GFC_ETC:-/etc/gfc-client}/customer-hosts.json"
  local mode_file="${GFC_ETC:-/etc/gfc-client}/proxy-mode.json"
  python3 - "$outfile" "$lan" "$port" "$wan" "$mode" "$hosts_file" "$mode_file" <<'PY'
import json, sys
from pathlib import Path
outfile, lan, port, wan, mode, hosts_file, mode_file = sys.argv[1:8]
file_mode = ""
if Path(mode_file).is_file():
    try:
        file_mode = str(json.loads(Path(mode_file).read_text()).get("mode") or "").lower()
    except (OSError, json.JSONDecodeError, TypeError):
        file_mode = ""
if mode != "bypass" and file_mode == "bypass":
    mode = "bypass"
hosts = []
if Path(hosts_file).is_file():
    try:
        raw = json.loads(Path(hosts_file).read_text()).get("hosts") or []
        if isinstance(raw, str):
            raw = raw.replace(",", " ").split()
        hosts = [str(x).strip() for x in raw if str(x).strip()]
    except (OSError, json.JSONDecodeError, TypeError):
        hosts = []
set_block = ""
wan_rules = ""
if mode == "bypass":
    elems = ", ".join(hosts)
    body = f"\n    elements = {{ {elems} }}" if elems else ""
    set_block = f"""
  set customer_hosts {{
    type ipv4_addr
    flags interval{body}
  }}"""
    if wan:
        wan_rules = f"""
    iifname "{wan}" ip saddr @customer_hosts udp dport 53 fib daddr type local return
    iifname "{wan}" ip saddr @customer_hosts tcp dport 53 fib daddr type local return
    iifname "{wan}" ip saddr @customer_hosts udp dport 53 redirect to :{port}
    iifname "{wan}" ip saddr @customer_hosts tcp dport 53 redirect to :{port}"""
text = f"""#!/usr/sbin/nft -f
# DNS hijack — docs/NFT_ARCHITECTURE.md (no skuid OUTPUT bypass)
table inet gfc_dns_hijack {{{set_block}
  chain prerouting {{
    type nat hook prerouting priority dstnat; policy accept;
    iifname "{lan}" udp dport 53 redirect to :{port}
    iifname "{lan}" tcp dport 53 redirect to :{port}{wan_rules}
  }}
}}
"""
Path(outfile).write_text(text)
PY
}

apply_gfc_nft_dns_conf() {
  local outfile="$1"
  if command -v nft >/dev/null; then
    nft list table inet gfc_dns_hijack &>/dev/null && nft delete table inet gfc_dns_hijack || true
    nft -f "$outfile"
  fi
}

fix_unbound_tree_perms() {
  local _gfc_etc="${1:-/etc/gfc-client}"
  mkdir -p /etc/unbound/conf.d /var/lib/unbound
  chown -R "$GFC_UNBOUND_USER:$GFC_UNBOUND_USER" /var/lib/unbound 2>/dev/null || true
  chmod 755 /etc/unbound /etc/unbound/conf.d
  mkdir -p /var/log/gfc-client
  touch /var/log/gfc-client/unbound.log
  chown "$GFC_UNBOUND_USER:$GFC_UNBOUND_USER" /var/log/gfc-client/unbound.log 2>/dev/null || true
}

# Legacy aliases
ensure_mosdns_user() { ensure_unbound_user; }
migrate_mosdns_user() { migrate_unbound_user; }
fix_mosdns_tree_perms() { fix_unbound_tree_perms "$@"; }
