#!/bin/sh
set -eu

GFC_ROOT="${GFC_ROOT:-/usr/lib/gfc-client}"
SRC="${GFC_ROOT}/deploy/immortalwrt/luci-app-gfc"

if [ ! -d "$SRC" ]; then
	echo "missing LuCI app source: $SRC" >&2
	exit 1
fi

mkdir -p /usr/share/luci/menu.d
mkdir -p /usr/share/rpcd/acl.d
mkdir -p /www/luci-static/resources/view/gfc

cp "$SRC/root/usr/share/luci/menu.d/luci-app-gfc.json" /usr/share/luci/menu.d/
cp "$SRC/root/usr/share/rpcd/acl.d/luci-app-gfc.json" /usr/share/rpcd/acl.d/
cp "$SRC/htdocs/luci-static/resources/view/gfc/"*.js /www/luci-static/resources/view/gfc/

/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart

echo "LuCI app installed. Open /cgi-bin/luci/admin/gfc"
