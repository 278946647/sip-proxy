#!/bin/sh
set -eu

GFC_ROOT="${GFC_ROOT:-/usr/lib/gfc-client}"
SRC="${GFC_ROOT}/deploy/immortalwrt/luci-app-gfc"
WWW_SRC="${GFC_ROOT}/deploy/immortalwrt/www"

if [ ! -d "$SRC" ]; then
	echo "missing LuCI app source: $SRC" >&2
	exit 1
fi

mkdir -p /usr/share/luci/menu.d
mkdir -p /usr/share/rpcd/acl.d
mkdir -p /www/luci-static/resources/view/gfc
mkdir -p /usr/share/ucode/luci/template/view/gfc
mkdir -p /www/cgi-bin
mkdir -p /www/gfc
mkdir -p /etc/uci-defaults

cp "$SRC/root/usr/share/luci/menu.d/luci-app-gfc.json" /usr/share/luci/menu.d/
cp "$SRC/root/usr/share/rpcd/acl.d/luci-app-gfc.json" /usr/share/rpcd/acl.d/
cp "$SRC/htdocs/luci-static/resources/view/gfc/"*.js /www/luci-static/resources/view/gfc/

if [ -f "$SRC/root/usr/share/ucode/luci/template/view/gfc/activate-banner.ut" ]; then
	cp "$SRC/root/usr/share/ucode/luci/template/view/gfc/activate-banner.ut" \
		/usr/share/ucode/luci/template/view/gfc/activate-banner.ut
fi

if [ -f "$SRC/root/etc/uci-defaults/99-gfc-portal" ]; then
	cp "$SRC/root/etc/uci-defaults/99-gfc-portal" /etc/uci-defaults/99-gfc-portal
	chmod +x /etc/uci-defaults/99-gfc-portal
fi

if [ -d "$WWW_SRC" ]; then
	cp -f "$WWW_SRC/cgi-bin/gfc-activation" /www/cgi-bin/gfc-activation
	chmod +x /www/cgi-bin/gfc-activation
	cp -f "$WWW_SRC/gfc/"* /www/gfc/
	cp -f "$WWW_SRC/index.html" /www/index.html
fi

# Apply portal + LuCI login banner hook.
if [ -x /etc/uci-defaults/99-gfc-portal ]; then
	/etc/uci-defaults/99-gfc-portal
fi

/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart

echo "LuCI app installed."
echo "  Device activation (no login): http://<device-ip>/gfc/activate.html"
echo "  LuCI GFC admin:             http://<device-ip>/cgi-bin/luci/admin/gfc"
echo "  Local API (LuCI backend):   http://127.0.0.1:8080/api/v1/health"
