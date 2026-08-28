#!/bin/sh
# ImmortalWrt/OpenWrt stock fw4 (firewall4) conflicts with GFC nft (gfc / gfc_dns_hijack / nat).
# GFC owns FORWARD/NAT/DNS hijack via gfc-routing; fw4 must stay stopped + disabled.
set -eu

# luci-mod-network DHCP/DNS does uci.load('firewall') unconditionally.
# OEM images omit firewall4, so /etc/config/firewall is missing → LuCI:
#   RPC call to uci/get failed with ubus code 4: 未找到资源
# Stub only — do not enable or start fw4.
if [ ! -s /etc/config/firewall ]; then
	cat >/etc/config/firewall <<'EOF'
# GFC stub: luci-mod-network requires this UCI config to exist.
# firewall4 / fw4 stays disabled; packet filter is inet gfc (gfc-routing).
EOF
	echo "fw4: wrote stub /etc/config/firewall for LuCI (service still disabled)"
fi

if [ ! -x /etc/init.d/firewall ]; then
	echo "fw4: no /etc/init.d/firewall (skip stop)"
	exit 0
fi

/etc/init.d/firewall stop 2>/dev/null || true
/etc/init.d/firewall disable 2>/dev/null || true

if /etc/init.d/firewall enabled >/dev/null 2>&1; then
	echo "WARN: fw4 still enabled in rc.d — check procd" >&2
	exit 1
fi

echo "fw4: stopped and disabled (GFC gfc-routing owns nft policy)"
