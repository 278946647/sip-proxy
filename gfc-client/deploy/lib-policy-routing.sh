#!/usr/bin/env bash
# Kernel policy routing: LAN forward → fwmark → table → gfctun → sing-box outbound.

GFC_POLICY_MARK="${GFC_POLICY_MARK:-0x2023}"
GFC_POLICY_TABLE="${GFC_POLICY_TABLE:-2022}"
GFC_TUN_INTERFACE="${GFC_TUN_INTERFACE:-gfctun}"

gfc_policy_mode_enabled() {
  local mode="${GFC_PROXY_MODE:-gateway}"
  case "$mode" in
    gateway | transparent) return 0 ;;
    *) return 1 ;;
  esac
}

# Resolve VLESS node + control-plane hostnames to IPv4 for nft bypass set.
resolve_policy_bypass_ips() {
  python3 - <<'PY'
import json, os, socket
from pathlib import Path
from urllib.parse import urlparse

seen: set[str] = set()
out: list[str] = []

def add_ip(ip: str) -> None:
    ip = ip.strip()
    if ip and ip not in seen:
        seen.add(ip)
        out.append(ip)

def add_host(host: str) -> None:
    host = (host or "").strip()
    if not host:
        return
    if host.startswith("["):
        host = host.strip("[]")
    try:
        for info in socket.getaddrinfo(host, None, socket.AF_INET):
            add_ip(info[4][0])
    except OSError:
        pass

for raw in os.environ.get("GFC_POLICY_BYPASS_IPS", "").split(","):
    token = raw.strip()
    if not token:
        continue
    if token.replace(".", "").isdigit() or "/" in token:
        add_ip(token.split("/")[0])
    else:
        add_host(token)

bundle = Path("/var/lib/gfc-client/state/config_bundle.json")
if bundle.is_file():
    try:
        payload = json.loads(bundle.read_text()).get("payload") or {}
    except (OSError, json.JSONDecodeError):
        payload = {}
    node = payload.get("node") or {}
    add_host(str(node.get("address") or ""))
    for srv in payload.get("controlPlaneServers") or []:
        s = str(srv).strip()
        if "://" in s:
            add_host(urlparse(s).hostname or "")
        else:
            add_host(s)

for env_key in ("GFC_NODE_BYPASS", "GFC_CP_BYPASS", "SERVER_URL", "SERVER_URL_FALLBACK"):
    raw = os.environ.get(env_key, "").strip()
    if not raw:
        continue
    if "://" in raw:
        add_host(urlparse(raw).hostname or "")
    else:
        add_host(raw)

print(", ".join(out))
PY
}

write_gfc_nft_policy_conf() {
  local lan="$1" lan_cidr="$2" outfile="$3"
  local bypass_ips="${4:-}"
  local script_dir gen_py

  export LAN="$lan"
  export LAN_CIDR="$lan_cidr"
  export WAN="${WAN:-${GFC_WAN_IFACE:-}}"
  export GFC_ROUTING_SCHEME="${GFC_ROUTING_SCHEME:-kernel-split}"
  if [[ -n "$bypass_ips" ]]; then
    export GFC_POLICY_BYPASS_IPS="$bypass_ips"
  fi

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  gen_py="${script_dir}/gen-nft-policy.py"
  if [[ ! -f "$gen_py" ]]; then
    echo "ERROR: ${gen_py} missing" >&2
    return 1
  fi
  python3 "$gen_py" "$outfile"
}

apply_gfc_nft_policy_conf() {
  local outfile="$1"
  local cn_load="${GFC_ETC:-/etc/gfc-client}/nftables-cn-ip-load.nft"
  if command -v nft >/dev/null; then
    nft list table inet gfc_client_mangle &>/dev/null && nft delete table inet gfc_client_mangle || true
    nft list table inet gfc &>/dev/null && nft delete table inet gfc || true
    nft -f "$outfile"
    if [[ -f "$cn_load" ]] && grep -q 'add element inet gfc TO_CN' "$cn_load" 2>/dev/null; then
      nft -f "$cn_load" && echo "    nft TO_CN load: ok"
    fi
  fi
}

# Re-render policy nft from network-roles.json + active bundle (node/CP bypass IPs).
refresh_gfc_policy_nft() {
  local gfc_etc="${GFC_ETC:-/etc/gfc-client}"
  local nft_policy="${gfc_etc}/nftables-policy.conf"
  local roles="${gfc_etc}/network-roles.json"
  local lan="" lan_cidr=""

  export GFC_ETC="$gfc_etc"

  if ! gfc_policy_mode_enabled; then
    return 0
  fi
  if [[ ! -f "$roles" ]]; then
    echo "    WARN: ${roles} missing — skip policy nft refresh" >&2
    return 0
  fi
  eval "$(python3 - <<'PY'
import json, os
from pathlib import Path
p = Path(os.environ.get("GFC_ETC", "/etc/gfc-client")) / "network-roles.json"
roles = json.loads(p.read_text())
print(f'LAN="{roles.get("lan", "")}"')
print(f'LAN_CIDR="{roles.get("lanNetwork", "")}"')
PY
)"
  if [[ -z "$lan" ]]; then
    lan="${GFC_LAN_IFACE:-${GFC_BRIDGE_NAME:-bridge_lan}}"
  fi
  if [[ -z "$lan_cidr" ]]; then
    lan_cidr="${GFC_LAN_CIDR:-${GFC_LAN_NETWORK:-192.168.68.0/24}}"
  fi
  if [[ -z "$lan" || -z "$lan_cidr" ]]; then
    echo "    WARN: lan/lanNetwork unknown — skip policy nft refresh" >&2
    return 0
  fi
  local bypass_ips
  bypass_ips="$(resolve_policy_bypass_ips)"
  write_gfc_nft_policy_conf "$lan" "$lan_cidr" "$nft_policy" "$bypass_ips"
  apply_gfc_nft_policy_conf "$nft_policy"
  echo "    policy nft refreshed (lan=${lan}, bypass=${bypass_ips:-none})"
}

teardown_gfc_nft_policy() {
  command -v nft >/dev/null && nft delete table inet gfc 2>/dev/null || true
  command -v nft >/dev/null && nft delete table inet gfc_client_mangle 2>/dev/null || true
}

purge_singbox_policy_routes() {
  local table="${GFC_POLICY_TABLE}"
  local tun="${GFC_TUN_INTERFACE}"
  # Remove sing-box auto_route leftovers and stray rules
  while ip -4 rule list 2>/dev/null | grep -qE "lookup ${table}"; do
    ip -4 rule del table "$table" 2>/dev/null || ip -4 rule del lookup "$table" 2>/dev/null || break
  done
  ip -4 route flush table "$table" 2>/dev/null || true
  # sing-box auto_redirect / auto_route may leave routes in main table
  local line dst
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ip -4 route del $line 2>/dev/null || true
  done < <(ip -4 route show table main 2>/dev/null | { grep "dev ${tun}" || true; })
  # Host /32 routes to public DNS/resolvers (auto_route artifact; breaks policy split)
  for dst in 1.0.0.1/32 1.1.1.1/32 8.8.4.4/32 8.8.8.8/32; do
    if ip -4 route show table main exact "$dst" 2>/dev/null | grep -qv "dev ${tun}"; then
      ip -4 route del "$dst" 2>/dev/null || true
    fi
  done
}

policy_ip_rule_present() {
  local table="${GFC_POLICY_TABLE}"
  local mark="${GFC_POLICY_MARK}"
  ip -4 rule list 2>/dev/null | grep -qE "fwmark ${mark}.*lookup ${table}" && return 0
  ip -4 rule list 2>/dev/null | grep -qE "fwmark .*lookup ${table}" && return 0
  return 1
}

purge_policy_ip_rule() {
  local mark="${GFC_POLICY_MARK:-0x2023}" table="${GFC_POLICY_TABLE:-2022}"
  local removed=0
  while ip -4 rule list 2>/dev/null | grep -qE "lookup ${table}"; do
    if ip -4 rule del pref 100 fwmark "$mark" lookup "$table" 2>/dev/null; then
      removed=1
      continue
    fi
    if ip -4 rule del fwmark "$mark" lookup "$table" 2>/dev/null; then
      removed=1
      continue
    fi
    if ip -4 rule del lookup "$table" 2>/dev/null; then
      removed=1
      continue
    fi
    break
  done
  if [[ "$removed" == "1" ]]; then
    echo "    ip rule: removed fwmark → table ${table} (router-only idle)"
  fi
}

ensure_policy_ip_rule() {
  local mark="${GFC_POLICY_MARK}"
  local table="${GFC_POLICY_TABLE}"

  if policy_ip_rule_present; then
    return 0
  fi
  if ip -4 rule add pref 100 fwmark "$mark" lookup "$table" 2>/dev/null; then
    echo "    ip rule: fwmark ${mark} lookup ${table}"
    return 0
  fi
  if ip -4 rule add pref 100 fwmark "$mark" table "$table"; then
    echo "    ip rule: fwmark ${mark} table ${table}"
    return 0
  fi
  echo "    ERROR: failed to add policy ip rule (mark=${mark} table=${table})" >&2
  return 1
}

ensure_policy_table_route() {
  local tun="${GFC_TUN_INTERFACE}"
  local table="${GFC_POLICY_TABLE}"
  local i

  for i in $(seq 1 30); do
    ip link show "$tun" &>/dev/null && break
    sleep 1
  done
  if ! ip link show "$tun" &>/dev/null; then
    echo "    WARN: ${tun} not up — table ${table} route not applied" >&2
    return 1
  fi
  ip -4 route replace default dev "$tun" table "$table"
  echo "    ip route: table ${table} default dev ${tun}"
}

apply_policy_routing() {
  local tun="${GFC_TUN_INTERFACE}"
  local table="${GFC_POLICY_TABLE}"
  local mark="${GFC_POLICY_MARK}"
  local script_dir cleanup

  if ! gfc_policy_mode_enabled; then
    echo "    policy routing: skipped (proxy_mode=${GFC_PROXY_MODE:-?})"
    return 0
  fi

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=lib-gfc-mode.sh
  source "${script_dir}/lib-gfc-mode.sh"
  if ! gfc_need_proxy_dataplane; then
    echo "    policy routing: skipped (router-only idle)"
    teardown_gfc_nft_policy 2>/dev/null || true
    teardown_policy_routing
    purge_policy_ip_rule 2>/dev/null || true
    return 0
  fi

  cleanup="${script_dir}/singbox-nft-cleanup.sh"
  if [[ -x "$cleanup" ]]; then
    bash "$cleanup" 2>/dev/null || true
  fi

  ensure_policy_ip_rule
  if ! ensure_policy_table_route; then
    echo "    WARN: gfctun route not applied" >&2
    return 1
  fi
  echo "    policy routing: fwmark ${mark} → table ${table} default dev ${tun}"
}

teardown_policy_routing() {
  local table="${GFC_POLICY_TABLE}"
  # Routes only; fwmark rule may be owned by netplan and survives gfc-routing stop.
  ip -4 route flush table "$table" 2>/dev/null || true
}
