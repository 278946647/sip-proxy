#!/bin/sh
# AmneziaWG client runtime for GFC boxes (ImmortalWrt).
# Reads <lib>/state/config_bundle.json; manages awg0 only. No auto switching.
#
# The ImmortalWrt amneziawg-tools package provides `awg` + the netifd proto,
# but NOT `awg-quick`. Interface lifecycle is therefore done explicitly:
#   ip link add type amneziawg -> addr/mtu/up -> awg setconf
set -eu

ACTION="${1:-apply}"
GFC_ROOT="${GFC_ROOT:-/usr/lib/gfc-client}"
GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
if [ -f "$GFC_ROOT/deploy/immortalwrt/lib-gfc-paths.sh" ]; then
	. "$GFC_ROOT/deploy/immortalwrt/lib-gfc-paths.sh"
	gfc_resolve_lib
fi
BUNDLE="${GFC_LIB:-/etc/gfc-client/lib}/state/config_bundle.json"
AWG_IFACE="${GFC_AWG_IFACE:-awg0}"
CONF="${GFC_ETC}/awg0.conf"
SETCONF="${GFC_ETC}/awg0.setconf"
APPLIED="${GFC_ETC}/awg0.applied"
APPLIED_SETCONF="${GFC_ETC}/awg0.applied.setconf"
TUN_IFACE="${GFC_TUN_INTERFACE:-gfctun}"
TABLE="${GFC_POLICY_TABLE:-2022}"
AWG_MSS="${GFC_AWG_MSS:-1360}"

json_path() {
	local f="$1" p="$2" key
	[ -f "$f" ] || return 0
	if command -v jsonfilter >/dev/null 2>&1; then
		jsonfilter -i "$f" -e "@.$p" 2>/dev/null || true
		return 0
	fi
	key="${p##*.}"
	awk -F'"' -v k="$key" '
		$0 ~ "\"" k "\"" {
			for (i = 1; i <= NF; i++) if ($i == k && $(i + 2) != "") { print $(i + 2); exit }
		}
	' "$f" 2>/dev/null || true
}

is_uint() {
	case "${1:-}" in
		'' | *[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

iface_up() {
	ip link show "$AWG_IFACE" >/dev/null 2>&1
}

set_active_route() {
	local dev="$1"
	[ -n "$dev" ] || return 0
	ip -4 route replace default dev "$dev" table "$TABLE" 2>/dev/null || \
		echo "WARN: awg: route $TABLE default dev $dev failed" >&2
}

destroy_iface() {
	if iface_up; then
		ip link del "$AWG_IFACE" 2>/dev/null || true
	fi
}

ensure_kernel() {
	modprobe amneziawg >/dev/null 2>&1 || true
	if [ ! -e /sys/module/amneziawg ]; then
		echo "ERROR: awg: kernel module amneziawg missing (kmod-amneziawg)" >&2
		return 1
	fi
	return 0
}

# create_iface <address> <mtu> <setconf-file>
create_iface() {
	local addr="$1" mtu="$2" conf="$3"
	destroy_iface
	ip link add dev "$AWG_IFACE" type amneziawg 2>/dev/null || {
		echo "ERROR: awg: ip link add type amneziawg failed" >&2
		return 1
	}
	ip addr add "$addr" dev "$AWG_IFACE" 2>/dev/null || {
		echo "ERROR: awg: addr $addr on $AWG_IFACE failed" >&2
		return 1
	}
	ip link set dev "$AWG_IFACE" mtu "$mtu" up 2>/dev/null || {
		echo "ERROR: awg: mtu/up $AWG_IFACE failed" >&2
		return 1
	}
	awg setconf "$AWG_IFACE" "$conf" 2>/dev/null || {
		echo "ERROR: awg: awg setconf $conf failed" >&2
		return 1
	}
	return 0
}

if [ ! -f "$BUNDLE" ]; then
	echo "awg: bundle missing ($BUNDLE), nothing to do" >&2
	exit 0
fi

TRANSPORT="$(json_path "$BUNDLE" transport | tr 'A-Z' 'a-z')"
[ -n "$TRANSPORT" ] || TRANSPORT="reality"

if [ "$ACTION" = "down" ]; then
	destroy_iface
	rm -f "$APPLIED" "$APPLIED_SETCONF"
	if ip link show "$TUN_IFACE" >/dev/null 2>&1; then
		set_active_route "$TUN_IFACE"
	fi
	echo "awg: down, table $TABLE default -> $TUN_IFACE"
	exit 0
fi

if [ "$TRANSPORT" != "awg" ]; then
	# Keep awg0 up for fast manual switch; only the default route moves.
	if ip link show "$TUN_IFACE" >/dev/null 2>&1; then
		set_active_route "$TUN_IFACE"
	fi
	echo "awg: transport=reality, table $TABLE default -> $TUN_IFACE"
	exit 0
fi

INNER_IP="$(json_path "$BUNDLE" awg.innerIp)"
ENDPOINT="$(json_path "$BUNDLE" awg.endpoint)"
PRIVATE_KEY="$(json_path "$BUNDLE" awg.privateKey)"
SERVER_KEY="$(json_path "$BUNDLE" awg.serverPublicKey)"
PSK="$(json_path "$BUNDLE" awg.presharedKey)"
MTU="$(json_path "$BUNDLE" awg.mtu)"
KEEPALIVE="$(json_path "$BUNDLE" awg.persistentKeepalive)"
JC="$(json_path "$BUNDLE" awg.obfuscation.jc)"
JMIN="$(json_path "$BUNDLE" awg.obfuscation.jmin)"
JMAX="$(json_path "$BUNDLE" awg.obfuscation.jmax)"
S1="$(json_path "$BUNDLE" awg.obfuscation.s1)"
S2="$(json_path "$BUNDLE" awg.obfuscation.s2)"
S3="$(json_path "$BUNDLE" awg.obfuscation.s3)"
S4="$(json_path "$BUNDLE" awg.obfuscation.s4)"
H1="$(json_path "$BUNDLE" awg.obfuscation.h1)"
H2="$(json_path "$BUNDLE" awg.obfuscation.h2)"
H3="$(json_path "$BUNDLE" awg.obfuscation.h3)"
H4="$(json_path "$BUNDLE" awg.obfuscation.h4)"
CHECKSUM="$(json_path "$BUNDLE" awg.checksum)"

for v in "$INNER_IP" "$ENDPOINT" "$PRIVATE_KEY" "$SERVER_KEY" "$JC" "$JMIN" \
	"$JMAX" "$S1" "$S2" "$H1" "$H2" "$H3" "$H4"; do
	if [ -z "$v" ]; then
		echo "ERROR: awg: incomplete awg block (missing field)" >&2
		exit 1
	fi
done
if ! command -v awg >/dev/null 2>&1; then
	echo "ERROR: awg: awg missing (install amneziawg-tools)" >&2
	exit 1
fi
ensure_kernel || exit 1
is_uint "$MTU" || MTU=1408
is_uint "$KEEPALIVE" || KEEPALIVE=25

mkdir -p "$GFC_ETC"
chmod 700 "$GFC_ETC" 2>/dev/null || true
TMP="${CONF}.tmp.$$"
TMP_SET="${SETCONF}.tmp.$$"
trap 'rm -f "$TMP" "$TMP_SET"' EXIT

# Full config kept for operators / troubleshooting.
{
	echo "[Interface]"
	echo "PrivateKey = $PRIVATE_KEY"
	echo "Address = $INNER_IP"
	echo "MTU = $MTU"
	echo "Table = off"
	echo "Jc = $JC"
	echo "Jmin = $JMIN"
	echo "Jmax = $JMAX"
	echo "S1 = $S1"
	echo "S2 = $S2"
	[ -n "$S3" ] && echo "S3 = $S3" || true
	[ -n "$S4" ] && echo "S4 = $S4" || true
	echo "H1 = $H1"
	echo "H2 = $H2"
	echo "H3 = $H3"
	echo "H4 = $H4"
	echo ""
	echo "[Peer]"
	echo "PublicKey = $SERVER_KEY"
	[ -n "$PSK" ] && echo "PresharedKey = $PSK" || true
	echo "Endpoint = $ENDPOINT"
	echo "AllowedIPs = 0.0.0.0/0"
	echo "PersistentKeepalive = $KEEPALIVE"
} >"$TMP"
chmod 600 "$TMP"

# `awg setconf` only accepts Interface/Peer keys (no Address/MTU/Table).
{
	echo "[Interface]"
	echo "PrivateKey = $PRIVATE_KEY"
	echo "Jc = $JC"
	echo "Jmin = $JMIN"
	echo "Jmax = $JMAX"
	echo "S1 = $S1"
	echo "S2 = $S2"
	[ -n "$S3" ] && echo "S3 = $S3" || true
	[ -n "$S4" ] && echo "S4 = $S4" || true
	echo "H1 = $H1"
	echo "H2 = $H2"
	echo "H3 = $H3"
	echo "H4 = $H4"
	echo ""
	echo "[Peer]"
	echo "PublicKey = $SERVER_KEY"
	[ -n "$PSK" ] && echo "PresharedKey = $PSK" || true
	echo "Endpoint = $ENDPOINT"
	echo "AllowedIPs = 0.0.0.0/0"
	echo "PersistentKeepalive = $KEEPALIVE"
} >"$TMP_SET"
chmod 600 "$TMP_SET"

if [ -f "$SETCONF" ] && cmp -s "$TMP_SET" "$SETCONF" && iface_up; then
	set_active_route "$AWG_IFACE"
	echo "awg: unchanged, table $TABLE default -> $AWG_IFACE (params ${CHECKSUM:-n/a})"
	exit 0
fi

# Keep the previous runtime for rollback.
if [ -f "$CONF" ] && [ -f "$SETCONF" ]; then
	cp -f "$CONF" "${CONF}.bak" 2>/dev/null || true
	cp -f "$SETCONF" "${SETCONF}.bak" 2>/dev/null || true
fi
mv "$TMP" "$CONF"
mv "$TMP_SET" "$SETCONF"
chmod 600 "$CONF" "$SETCONF"
trap - EXIT

if create_iface "$INNER_IP" "$MTU" "$SETCONF"; then
	cp -f "$CONF" "$APPLIED" 2>/dev/null || true
	cp -f "$SETCONF" "$APPLIED_SETCONF" 2>/dev/null || true
	set_active_route "$AWG_IFACE"
	echo "awg: up $AWG_IFACE inner=$INNER_IP endpoint=$ENDPOINT mtu=$MTU table=$TABLE"
	exit 0
fi

echo "ERROR: awg apply failed; restoring previous config" >&2
destroy_iface
if [ -f "${CONF}.bak" ] && [ -f "${SETCONF}.bak" ]; then
	old_addr="$(sed -n 's/^Address = //p' "${CONF}.bak" | head -1)"
	old_mtu="$(sed -n 's/^MTU = //p' "${CONF}.bak" | head -1)"
	is_uint "$old_mtu" || old_mtu=1408
	if [ -n "$old_addr" ]; then
		create_iface "$old_addr" "$old_mtu" "${SETCONF}.bak" || true
		cp -f "${CONF}.bak" "$CONF" 2>/dev/null || true
		cp -f "${SETCONF}.bak" "$SETCONF" 2>/dev/null || true
	fi
fi
if ip link show "$TUN_IFACE" >/dev/null 2>&1; then
	set_active_route "$TUN_IFACE"
fi
exit 1
