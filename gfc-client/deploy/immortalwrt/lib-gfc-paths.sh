#!/bin/sh
# OpenWrt /var is a symlink to tmpfs /tmp. Persist GFC lib (bundle, token, sqlite)
# under overlay-backed /etc/gfc-client/lib. Ubuntu keeps /var/lib/gfc-client.
#
# Usage: . this file, then gfc_resolve_lib and optionally gfc_migrate_volatile_lib.

GFC_LIB_OPENWRT="${GFC_LIB_OPENWRT:-/etc/gfc-client/lib}"
GFC_LIB_VOLATILE="${GFC_LIB_VOLATILE:-/var/lib/gfc-client}"

gfc_is_openwrt() {
	[ -f /etc/openwrt_release ] && return 0
	case "${GFC_PLATFORM:-}" in
		immortalwrt|openwrt) return 0 ;;
	esac
	return 1
}

gfc_is_legacy_volatile_lib() {
	case "${1:-}" in
		""|"$GFC_LIB_VOLATILE"|/tmp/lib/gfc-client) return 0 ;;
	esac
	return 1
}

gfc_resolve_lib() {
	if gfc_is_openwrt && gfc_is_legacy_volatile_lib "${GFC_LIB:-}"; then
		GFC_LIB="$GFC_LIB_OPENWRT"
		return 0
	fi
	if [ -z "${GFC_LIB:-}" ]; then
		GFC_LIB="$GFC_LIB_VOLATILE"
	fi
}

gfc_rewrite_env_lib() {
	local envf="${GFC_ENV_FILE:-${GFC_ETC:-/etc/gfc-client}/gfc.env}"
	[ -f "$envf" ] || return 0
	gfc_is_openwrt || return 0
	if grep -q '^GFC_LIB=/var/lib/gfc-client' "$envf" 2>/dev/null; then
		sed -i 's|^GFC_LIB=/var/lib/gfc-client|GFC_LIB=/etc/gfc-client/lib|' "$envf" 2>/dev/null || true
	fi
	if ! grep -q '^GFC_LIB=' "$envf" 2>/dev/null; then
		echo "GFC_LIB=/etc/gfc-client/lib" >>"$envf"
	fi
}

gfc_copy_if_missing() {
	local src="$1" dest="$2"
	[ -f "$src" ] || return 0
	[ -f "$dest" ] && return 0
	mkdir -p "$(dirname "$dest")"
	cp -a "$src" "$dest" 2>/dev/null || true
}

gfc_copy_dir_if_empty() {
	local src="$1" dest="$2"
	[ -d "$src" ] || return 0
	mkdir -p "$dest"
	if [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
		return 0
	fi
	cp -a "$src/." "$dest/" 2>/dev/null || true
}

gfc_migrate_volatile_lib() {
	gfc_resolve_lib
	gfc_rewrite_env_lib
	mkdir -p "$GFC_LIB/state" "$GFC_LIB/rules" "$GFC_LIB/dns-lists" "$GFC_LIB/backups"
	gfc_is_openwrt || return 0
	local src
	for src in "$GFC_LIB_VOLATILE" /tmp/lib/gfc-client; do
		[ -d "$src" ] || continue
		[ "$src" = "$GFC_LIB" ] && continue
		gfc_copy_if_missing "$src/state/config_bundle.json" "$GFC_LIB/state/config_bundle.json"
		gfc_copy_if_missing "$src/state/client_state.json" "$GFC_LIB/state/client_state.json"
		gfc_copy_if_missing "$src/state/ota-result.json" "$GFC_LIB/state/ota-result.json"
		gfc_copy_if_missing "$src/gfc-client.db" "$GFC_LIB/gfc-client.db"
		gfc_copy_if_missing "$src/status.json" "$GFC_LIB/status.json"
		gfc_copy_dir_if_empty "$src/rules" "$GFC_LIB/rules"
		gfc_copy_dir_if_empty "$src/dns-lists" "$GFC_LIB/dns-lists"
		gfc_copy_dir_if_empty "$src/backups" "$GFC_LIB/backups"
	done
}
