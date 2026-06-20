#!/bin/sh
set -eu

GFC_ROOT="${GFC_ROOT:-/usr/lib/gfc-client}"
GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
GFC_LIB="${GFC_LIB:-/var/lib/gfc-client}"
GFC_LOG_DIR="${GFC_LOG_DIR:-/var/log/gfc-client}"
INIT_SRC="${GFC_ROOT}/deploy/immortalwrt/package/files/etc/init.d"

stop_service() {
	local svc="$1"
	"/etc/init.d/$svc" stop 2>/dev/null || true
}

start_service() {
	local svc="$1"
	"/etc/init.d/$svc" start 2>/dev/null || true
}

stop_service gfc-agent
stop_service gfc-api
stop_service gfc-mosdns
stop_service gfc-sing-box
stop_service gfc-routing

pkill gfc-api 2>/dev/null || true
pkill gfc-agent 2>/dev/null || true
pkill gfc-bootstrap 2>/dev/null || true
sleep 1

for bin in gfc-api gfc-agent gfc-bootstrap; do
	if [ -f "/tmp/$bin" ]; then
		mv "/tmp/$bin" "/usr/bin/$bin"
		chmod +x "/usr/bin/$bin"
	fi
done

chmod +x /usr/lib/gfc-client/deploy/immortalwrt/*.sh 2>/dev/null || true

if [ -d "$INIT_SRC" ]; then
	for svc in gfc-api gfc-agent gfc-mosdns gfc-sing-box gfc-routing; do
		cp "$INIT_SRC/$svc" "/etc/init.d/$svc"
		chmod +x "/etc/init.d/$svc"
	done
fi

if [ -x /usr/bin/gfc-bootstrap ]; then
	GFC_PLATFORM=immortalwrt \
	GFC_ROOT="$GFC_ROOT" \
	GFC_ETC="$GFC_ETC" \
	GFC_LIB="$GFC_LIB" \
	GFC_LOG_DIR="$GFC_LOG_DIR" \
	gfc-bootstrap || true
fi

if [ -x /usr/lib/gfc-client/deploy/immortalwrt/install-luci-app.sh ]; then
	/usr/lib/gfc-client/deploy/immortalwrt/install-luci-app.sh || true
fi

rm -rf /tmp/luci-indexcache /tmp/luci-modulecache

start_service gfc-api
start_service gfc-mosdns
/etc/init.d/dnsmasq restart 2>/dev/null || true
start_service gfc-agent
start_service gfc-sing-box
start_service gfc-routing

echo "GFC runtime upgraded"
