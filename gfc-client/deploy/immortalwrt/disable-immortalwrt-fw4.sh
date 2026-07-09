#!/bin/sh
# ImmortalWrt/OpenWrt stock fw4 (firewall4) conflicts with GFC nft (gfc / gfc_dns_hijack / nat).
# GFC owns FORWARD/NAT/DNS hijack via gfc-routing; fw4 must stay stopped + disabled.
set -eu

if [ ! -x /etc/init.d/firewall ]; then
	echo "fw4: no /etc/init.d/firewall (skip)"
	exit 0
fi

/etc/init.d/firewall stop 2>/dev/null || true
/etc/init.d/firewall disable 2>/dev/null || true

if /etc/init.d/firewall enabled >/dev/null 2>&1; then
	echo "WARN: fw4 still enabled in rc.d — check procd" >&2
	exit 1
fi

echo "fw4: stopped and disabled (GFC gfc-routing owns nft policy)"
