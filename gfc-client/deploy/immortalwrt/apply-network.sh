#!/bin/sh
set -eu

export GFC_PLATFORM="${GFC_PLATFORM:-immortalwrt}"
export GFC_ENV_FILE="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
export GFC_ROOT="${GFC_ROOT:-/usr/lib/gfc-client}"
export GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
export GFC_LIB="${GFC_LIB:-}"
if [ -f "$GFC_ROOT/deploy/immortalwrt/lib-gfc-paths.sh" ]; then
	. "$GFC_ROOT/deploy/immortalwrt/lib-gfc-paths.sh"
	gfc_resolve_lib
fi
export GFC_LIB="${GFC_LIB:-/etc/gfc-client/lib}"
export GFC_LOG_DIR="${GFC_LOG_DIR:-/var/log/gfc-client}"

exec /usr/bin/gfc-bootstrap --apply-network
