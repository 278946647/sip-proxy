#!/bin/sh
# Apply HTB rate limit on gfctun from config bundle bandwidthMbps.
# Egress: direct HTB on TUN. Ingress: IFB redirect (symmetric Mbps cap).
set -eu

ACTION="${1:-apply}"
ENV_FILE="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

GFC_ROOT="${GFC_ROOT:-/usr/lib/gfc-client}"
GFC_LIB="${GFC_LIB:-/var/lib/gfc-client}"
IFACE="${GFC_TUN_INTERFACE:-gfctun}"
IFB="${GFC_IFB_INTERFACE:-ifb-gfc}"
BUNDLE="${GFC_LIB}/state/config_bundle.json"

read_bandwidth_mbps() {
	if [ ! -f "$BUNDLE" ]; then
		return 1
	fi
	awk '
		/"bandwidthMbps"[[:space:]]*:/ {
			line = $0
			sub(/.*"bandwidthMbps"[[:space:]]*:[[:space:]]*/, "", line)
			sub(/[^0-9].*/, "", line)
			if (line ~ /^[0-9]+$/) {
				print line
				exit
			}
		}
	' "$BUNDLE"
}

teardown_shaping() {
	if ! command -v tc >/dev/null 2>&1; then
		return 0
	fi
	tc qdisc del dev "$IFACE" root 2>/dev/null || true
	tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
	if ip link show "$IFB" >/dev/null 2>&1; then
		tc qdisc del dev "$IFB" root 2>/dev/null || true
		ip link del "$IFB" 2>/dev/null || true
	fi
}

wait_iface() {
	local i
	for i in $(seq 1 30); do
		ip link show "$IFACE" >/dev/null 2>&1 && return 0
		sleep 1
	done
	return 1
}

apply_shaping() {
	local rate_mbps="$1"

	if [ -z "$rate_mbps" ] || [ "$rate_mbps" -lt 1 ] 2>/dev/null; then
		teardown_shaping
		echo "tc htb: skipped (no bandwidth)"
		return 0
	fi

	if ! command -v tc >/dev/null 2>&1; then
		echo "WARN: tc not installed; skip bandwidth shaping" >&2
		return 0
	fi

	if ! wait_iface; then
		echo "WARN: ${IFACE} not up; bandwidth shaping deferred" >&2
		return 0
	fi

	modprobe ifb numifbs=8 2>/dev/null || true

	teardown_shaping

	# Upload path: LAN → gfctun → sing-box
	tc qdisc add dev "$IFACE" root handle 1: htb default 10
	tc class add dev "$IFACE" parent 1: classid 1:1 htb rate "${rate_mbps}mbit" ceil "${rate_mbps}mbit"
	tc class add dev "$IFACE" parent 1:1 classid 1:10 htb rate "${rate_mbps}mbit" ceil "${rate_mbps}mbit" prio 0
	tc qdisc add dev "$IFACE" parent 1:10 handle 10: fq_codel 2>/dev/null || true

	# Download path: sing-box → gfctun → LAN (ingress redirect to IFB)
	ip link add "$IFB" type ifb 2>/dev/null || true
	ip link set "$IFB" up 2>/dev/null || true

	tc qdisc add dev "$IFACE" handle ffff: ingress
	tc filter add dev "$IFACE" parent ffff: protocol all u32 match u32 0 0 \
		action mirred egress redirect dev "$IFB" 2>/dev/null || true

	tc qdisc add dev "$IFB" root handle 2: htb default 20
	tc class add dev "$IFB" parent 2: classid 2:1 htb rate "${rate_mbps}mbit" ceil "${rate_mbps}mbit"
	tc class add dev "$IFB" parent 2:1 classid 2:20 htb rate "${rate_mbps}mbit" ceil "${rate_mbps}mbit" prio 0
	tc qdisc add dev "$IFB" parent 2:20 handle 20: fq_codel 2>/dev/null || true

	echo "tc htb: ${IFACE} egress+ingress ${rate_mbps}mbit (ifb=${IFB})"
}

case "$ACTION" in
	apply)
		rate="$(read_bandwidth_mbps 2>/dev/null || true)"
		apply_shaping "$rate"
		;;
	remove|teardown)
		teardown_shaping
		echo "tc htb: removed"
		;;
	*)
		echo "usage: $0 {apply|remove}" >&2
		exit 2
		;;
esac
