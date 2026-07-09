#!/bin/sh
# Prepare unbound directories required by GFC config (auto-trust-anchor-file, conf.d).
set -eu

GFC_LOG_DIR="${GFC_LOG_DIR:-/var/log/gfc-client}"
GFC_UNBOUND_USER="${GFC_UNBOUND_USER:-unbound}"

mkdir -p /etc/unbound/conf.d /var/lib/unbound /var/lib/unbound/etc/unbound "$GFC_LOG_DIR"

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
