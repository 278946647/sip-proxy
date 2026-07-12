#!/bin/sh
# OEM: listen SSH on GFC_SSH_PORT (default 212). Keep 22 briefly if GFC_SSH_KEEP_22=1.
set -eu

ENV_FILE="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

SSH_PORT="${GFC_SSH_PORT:-212}"
KEEP22="${GFC_SSH_KEEP_22:-0}"

if ! command -v uci >/dev/null 2>&1; then
	exit 0
fi
if ! uci -q get dropbear.@dropbear[0] >/dev/null 2>&1; then
	echo "dropbear: no UCI section (skip)"
	exit 0
fi

# Primary instance → GFC admin port.
uci set dropbear.@dropbear[0].Port="$SSH_PORT"
uci set dropbear.@dropbear[0].Interface='' 

# Optional second instance on 22 for migration.
if [ "$KEEP22" = "1" ]; then
	idx="$(uci -q show dropbear | grep -c '=dropbear' || true)"
	if [ "${idx:-0}" -lt 2 ]; then
		uci add dropbear dropbear >/dev/null
		uci set dropbear.@dropbear[-1].Port='22'
		uci set dropbear.@dropbear[-1].PasswordAuth='on'
		uci set dropbear.@dropbear[-1].RootPasswordAuth='on'
	fi
else
	# Remove extra instances that only listen on 22 (keep first which is now 212).
	i=1
	while uci -q get dropbear.@dropbear[$i] >/dev/null 2>&1; do
		p="$(uci -q get dropbear.@dropbear[$i].Port 2>/dev/null || true)"
		if [ "$p" = "22" ]; then
			uci -q delete dropbear.@dropbear[$i] || true
		else
			i=$((i + 1))
		fi
	done
fi

uci commit dropbear
echo "dropbear: Port=$SSH_PORT (GFC_SSH_KEEP_22=$KEEP22)"

if [ -x /etc/init.d/dropbear ]; then
	/etc/init.d/dropbear restart 2>/dev/null || true
fi
