#!/usr/bin/env bash
# MosDNS system identity + OUTPUT DNS hijack (skuid-based, fixed uid).
GFC_MOSDNS_UID="${GFC_MOSDNS_UID:-65353}"
GFC_MOSDNS_USER="${GFC_MOSDNS_USER:-mosdns}"

ensure_mosdns_user() {
  if ! getent group "$GFC_MOSDNS_USER" >/dev/null; then
    groupadd -r "$GFC_MOSDNS_USER"
  fi
  if id -u "$GFC_MOSDNS_USER" &>/dev/null; then
    return 0
  fi
  if getent passwd "$GFC_MOSDNS_UID" >/dev/null; then
    echo "ERROR: uid ${GFC_MOSDNS_UID} already used by $(getent passwd "$GFC_MOSDNS_UID" | cut -d: -f1)" >&2
    return 1
  fi
  useradd -r -u "$GFC_MOSDNS_UID" -g "$GFC_MOSDNS_USER" -s /usr/sbin/nologin \
    -d /var/lib/gfc-client -M "$GFC_MOSDNS_USER"
}

# Recreate mosdns when uid drifted (e.g. user created before fixed-uid install).
migrate_mosdns_user() {
  if ! getent group "$GFC_MOSDNS_USER" >/dev/null; then
    groupadd -r "$GFC_MOSDNS_USER"
  fi
  if id -u "$GFC_MOSDNS_USER" &>/dev/null; then
    local uid
    uid="$(id -u "$GFC_MOSDNS_USER")"
    if [[ "$uid" == "$GFC_MOSDNS_UID" ]]; then
      return 0
    fi
    echo "    migrate ${GFC_MOSDNS_USER} uid ${uid} -> ${GFC_MOSDNS_UID}"
    systemctl stop gfc-mosdns.service 2>/dev/null || true
    userdel "$GFC_MOSDNS_USER" 2>/dev/null || true
  fi
  if getent passwd "$GFC_MOSDNS_UID" >/dev/null; then
    echo "ERROR: uid ${GFC_MOSDNS_UID} already used by $(getent passwd "$GFC_MOSDNS_UID" | cut -d: -f1)" >&2
    return 1
  fi
  useradd -r -u "$GFC_MOSDNS_UID" -g "$GFC_MOSDNS_USER" -s /usr/sbin/nologin \
    -d /var/lib/gfc-client -M "$GFC_MOSDNS_USER"
}

write_gfc_nft_dns_conf() {
  local lan="$1" port="$2" outfile="$3"
  cat >"$outfile" <<EOF
#!/usr/sbin/nft -f
table inet gfc_dns_hijack {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "${lan}" udp dport 53 redirect to :${port}
    iifname "${lan}" tcp dport 53 redirect to :${port}
  }
  chain output_dns {
    type nat hook output priority -100; policy accept;
    meta skuid != ${GFC_MOSDNS_UID} ip daddr != 127.0.0.1 udp dport 53 redirect to :${port}
    meta skuid != ${GFC_MOSDNS_UID} ip daddr != 127.0.0.1 tcp dport 53 redirect to :${port}
  }
}
EOF
}

apply_gfc_nft_dns_conf() {
  local outfile="$1"
  if command -v nft >/dev/null; then
    nft list table inet gfc_dns_hijack &>/dev/null && nft delete table inet gfc_dns_hijack || true
    nft -f "$outfile"
  fi
}

fix_mosdns_tree_perms() {
  local gfc_etc="${1:-/etc/gfc-client}"
  chmod 755 "$gfc_etc"
  if [[ -d "${gfc_etc}/mosdns" ]]; then
    chown -R root:"$GFC_MOSDNS_USER" "${gfc_etc}/mosdns"
    find "${gfc_etc}/mosdns" -type d -exec chmod 750 {} \;
    find "${gfc_etc}/mosdns" -type f -exec chmod 640 {} \;
  fi
  mkdir -p /var/log/gfc-client
  touch /var/log/gfc-client/mosdns.log
  chown "$GFC_MOSDNS_USER:$GFC_MOSDNS_USER" /var/log/gfc-client/mosdns.log 2>/dev/null || true
}
