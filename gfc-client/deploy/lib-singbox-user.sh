#!/usr/bin/env bash
# sing-box system identity (fixed uid for nft meta skuid exemption).
GFC_SINGBOX_UID="${GFC_SINGBOX_UID:-65354}"
GFC_SINGBOX_USER="${GFC_SINGBOX_USER:-singbox}"

ensure_singbox_user() {
  if ! getent group "$GFC_SINGBOX_USER" >/dev/null; then
    groupadd -r "$GFC_SINGBOX_USER"
  fi
  if id -u "$GFC_SINGBOX_USER" &>/dev/null; then
    return 0
  fi
  if getent passwd "$GFC_SINGBOX_UID" >/dev/null; then
    echo "ERROR: uid ${GFC_SINGBOX_UID} already used by $(getent passwd "$GFC_SINGBOX_UID" | cut -d: -f1)" >&2
    return 1
  fi
  useradd -r -u "$GFC_SINGBOX_UID" -g "$GFC_SINGBOX_USER" -s /usr/sbin/nologin \
    -d /var/lib/gfc-client -M "$GFC_SINGBOX_USER"
}

migrate_singbox_user() {
  if ! getent group "$GFC_SINGBOX_USER" >/dev/null; then
    groupadd -r "$GFC_SINGBOX_USER"
  fi
  if id -u "$GFC_SINGBOX_USER" &>/dev/null; then
    local uid
    uid="$(id -u "$GFC_SINGBOX_USER")"
    if [[ "$uid" == "$GFC_SINGBOX_UID" ]]; then
      return 0
    fi
    echo "    migrate ${GFC_SINGBOX_USER} uid ${uid} -> ${GFC_SINGBOX_UID}"
    systemctl stop gfc-sing-box.service 2>/dev/null || true
    userdel "$GFC_SINGBOX_USER" 2>/dev/null || true
  fi
  if getent passwd "$GFC_SINGBOX_UID" >/dev/null; then
    echo "ERROR: uid ${GFC_SINGBOX_UID} already used by $(getent passwd "$GFC_SINGBOX_UID" | cut -d: -f1)" >&2
    return 1
  fi
  useradd -r -u "$GFC_SINGBOX_UID" -g "$GFC_SINGBOX_USER" -s /usr/sbin/nologin \
    -d /var/lib/gfc-client -M "$GFC_SINGBOX_USER"
}

fix_singbox_tree_perms() {
  local gfc_etc="${1:-/etc/gfc-client}"
  chmod 755 "$gfc_etc"
  if [[ -f "${gfc_etc}/sing-box.json" ]]; then
    chown root:"$GFC_SINGBOX_USER" "${gfc_etc}/sing-box.json"
    chmod 640 "${gfc_etc}/sing-box.json"
  fi
  mkdir -p /var/log/gfc-client
  touch /var/log/gfc-client/sing-box.log
  chown "$GFC_SINGBOX_USER:$GFC_SINGBOX_USER" /var/log/gfc-client/sing-box.log 2>/dev/null || true
}
