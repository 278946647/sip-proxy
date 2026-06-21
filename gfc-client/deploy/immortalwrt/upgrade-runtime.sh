#!/bin/sh
set -eu

GFC_ROOT="${GFC_ROOT:-/usr/lib/gfc-client}"
GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
GFC_LIB="${GFC_LIB:-/var/lib/gfc-client}"
GFC_LOG_DIR="${GFC_LOG_DIR:-/var/log/gfc-client}"
GFC_MOSDNS_USER="${GFC_MOSDNS_USER:-mosdns}"
GFC_MOSDNS_UID="${GFC_MOSDNS_UID:-65353}"
INIT_SRC="${GFC_ROOT}/deploy/immortalwrt/package/files/etc/init.d"

stop_service() {
	local svc="$1"
	"/etc/init.d/$svc" stop 2>/dev/null || true
}

start_service() {
	local svc="$1"
	"/etc/init.d/$svc" start 2>/dev/null || true
}

ensure_group() {
	local name="$1" gid="$2"
	if grep -q "^${name}:" /etc/group 2>/dev/null; then
		return 0
	fi
	if command -v addgroup >/dev/null 2>&1; then
		addgroup -S -g "$gid" "$name" 2>/dev/null || addgroup "$name" 2>/dev/null || true
	fi
	if ! grep -q "^${name}:" /etc/group 2>/dev/null; then
		echo "${name}:x:${gid}:" >> /etc/group
	fi
}

ensure_user() {
	local name="$1" uid="$2" group="$3"
	if grep -q "^${name}:" /etc/passwd 2>/dev/null; then
		return 0
	fi
	if command -v adduser >/dev/null 2>&1; then
		adduser -S -D -H -u "$uid" -G "$group" -s /bin/false "$name" 2>/dev/null || true
	fi
	if ! grep -q "^${name}:" /etc/passwd 2>/dev/null; then
		echo "${name}:x:${uid}:${uid}:GFC ${name}:/var/lib/gfc-client:/bin/false" >> /etc/passwd
	fi
}

env_set() {
	local key="$1" value="$2" file="$GFC_ETC/gfc.env"
	mkdir -p "$GFC_ETC"
	touch "$file"
	if grep -q "^${key}=" "$file" 2>/dev/null; then
		sed -i "s|^${key}=.*|${key}=${value}|" "$file"
	else
		echo "${key}=${value}" >> "$file"
	fi
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

ensure_group "$GFC_MOSDNS_USER" "$GFC_MOSDNS_UID"
ensure_user "$GFC_MOSDNS_USER" "$GFC_MOSDNS_UID" "$GFC_MOSDNS_USER"
env_set GFC_ENABLE_OUTPUT_POLICY 1
env_set GFC_MOSDNS_USER "$GFC_MOSDNS_USER"
env_set GFC_MOSDNS_UID "$GFC_MOSDNS_UID"

if [ -d "$INIT_SRC" ]; then
	for svc in gfc-api gfc-agent gfc-mosdns gfc-sing-box gfc-routing; do
		cp "$INIT_SRC/$svc" "/etc/init.d/$svc"
		chmod +x "/etc/init.d/$svc"
	done
fi

if [ -x /usr/bin/gfc-bootstrap ]; then
	run_bootstrap() {
		GFC_PLATFORM=immortalwrt \
		GFC_ROOT="$GFC_ROOT" \
		GFC_ETC="$GFC_ETC" \
		GFC_LIB="$GFC_LIB" \
		GFC_LOG_DIR="$GFC_LOG_DIR" \
		gfc-bootstrap "$@"
	}
	if [ -f "$GFC_LIB/state/config_bundle.json" ]; then
		run_bootstrap --reapply || echo "WARN: active dataplane reapply failed; keeping existing config" >&2
	else
		run_bootstrap || true
	fi
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
