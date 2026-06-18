#!/usr/bin/env bash
# Router-only idle vs proxy dataplane (TUN + kernel-split nft).

GFC_ETC="${GFC_ETC:-/etc/gfc-client}"

# True when sing-box config includes a TUN inbound (line activated / reapply done).
gfc_need_proxy_dataplane() {
  local cfg="${GFC_ETC}/sing-box.json"
  [[ -f "$cfg" ]] || return 1
  grep -qE '"type"[[:space:]]*:[[:space:]]*"tun"' "$cfg" 2>/dev/null
}

gfc_router_only_mode() {
  ! gfc_need_proxy_dataplane
}
