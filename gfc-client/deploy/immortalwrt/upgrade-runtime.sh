#!/bin/sh
set -eu

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

if [ -x /usr/lib/gfc-client/deploy/immortalwrt/install-luci-app.sh ]; then
	/usr/lib/gfc-client/deploy/immortalwrt/install-luci-app.sh || true
fi

rm -rf /tmp/luci-indexcache /tmp/luci-modulecache

start_service gfc-api
start_service gfc-agent

echo "GFC runtime upgraded"
