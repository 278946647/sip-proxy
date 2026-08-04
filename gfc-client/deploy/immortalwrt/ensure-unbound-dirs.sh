#!/bin/sh
# Prepare unbound directories required by GFC config (auto-trust-anchor-file, conf.d).
set -eu

GFC_LOG_DIR="${GFC_LOG_DIR:-/var/log/gfc-client}"
GFC_UNBOUND_USER="${GFC_UNBOUND_USER:-unbound}"

mkdir -p /etc/unbound/conf.d /etc/unbound/local.d /var/lib/unbound /var/lib/unbound/etc/unbound "$GFC_LOG_DIR"

_ensure_snippet() {
	_dst="$1"
	shift
	if [ -f "$_dst" ]; then
		return 0
	fi
	printf '%s\n' "$@" >"$_dst"
	chmod 644 "$_dst" 2>/dev/null || true
}

_ensure_snippet /etc/unbound/conf.d/gfc-domestic-forward.conf \
	'# Generated from gfc-domestic-forward.list — do not hand-edit; edit via LuCI DSL' \
	'# forward-zone MUST stay outside server: (UNBOUND_ARCHITECTURE)' \
	'# (empty)'

_ensure_snippet /etc/unbound/local.d/gfc-block.conf \
	'# Generated from gfc-block.list — do not hand-edit; edit via LuCI DSL' \
	'server:' \
	'    # (empty)'

_ensure_snippet /etc/unbound/local.d/gfc-static.conf \
	'# Generated from gfc-static.list — do not hand-edit; edit via LuCI DSL' \
	'server:' \
	'    # (empty)'

# unbound-checkconf on ImmortalWrt validates paths inside default chroot (/var/lib/unbound).
# GFC config keeps auto-trust-anchor-file at /var/lib/unbound/root.key and sets chroot: "".
if [ ! -s /var/lib/unbound/root.key ]; then
	if [ -s /etc/unbound/root.key ]; then
		cp /etc/unbound/root.key /var/lib/unbound/root.key 2>/dev/null || true
	else
		touch /var/lib/unbound/root.key
	fi
	chmod 644 /var/lib/unbound/root.key 2>/dev/null || true
fi
if [ ! -f /var/lib/unbound/etc/unbound/root.key ]; then
	cp /var/lib/unbound/root.key /var/lib/unbound/etc/unbound/root.key 2>/dev/null \
		|| touch /var/lib/unbound/etc/unbound/root.key
	chmod 644 /var/lib/unbound/etc/unbound/root.key 2>/dev/null || true
fi

if id "$GFC_UNBOUND_USER" >/dev/null 2>&1; then
	chown -R "$GFC_UNBOUND_USER:$GFC_UNBOUND_USER" /var/lib/unbound 2>/dev/null || true
	chown "$GFC_UNBOUND_USER:$GFC_UNBOUND_USER" "$GFC_LOG_DIR" 2>/dev/null || true
fi

touch "$GFC_LOG_DIR/unbound.log" 2>/dev/null || true
chmod 755 /etc/unbound /etc/unbound/conf.d 2>/dev/null || true
