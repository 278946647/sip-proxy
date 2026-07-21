include $(TOPDIR)/rules.mk

PKG_NAME:=gfc-client
PKG_VERSION:=1.1.0
PKG_RELEASE:=23
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)
PKG_BUILD_DEPENDS:=golang/host
GFC_CLIENT_SRC ?= $(abspath $(CURDIR)/../../..)

# OpenWrt ARCH → Go GOARCH (GO_ARCH from golang/host when available)
GFC_GOARCH=$(if $(GO_ARCH),$(GO_ARCH),$(if $(filter $(ARCH),x86_64),amd64,$(if $(filter $(ARCH),aarch64),arm64,$(ARCH))))
GFC_GOFLAGS?=-buildvcs=false

include $(INCLUDE_DIR)/package.mk

define Package/gfc-client
  SECTION:=net
  CATEGORY:=Network
  TITLE:=GFC client box management agent
  # No runtime DEPENDS — invalid/missing deps remove gfc-client from Kconfig entirely.
  # All runtime packages are selected via config/gfc-packages.config (+ ensure-gfc-package-index.sh).
  DEPENDS:=
endef

define Package/gfc-client/description
GFC client agent and LuCI-backed API for ImmortalWrt/OpenWrt boxes.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(GFC_CLIENT_SRC)/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) build-openwrt \
		GOOS=linux GOARCH=$(GFC_GOARCH) CGO_ENABLED=0 GOFLAGS="$(GFC_GOFLAGS)"
endef

define Package/gfc-client/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/bin/gfc-api $(1)/usr/bin/gfc-api
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/bin/gfc-agent $(1)/usr/bin/gfc-agent
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/bin/gfc-bootstrap $(1)/usr/bin/gfc-bootstrap

	$(INSTALL_DIR) $(1)/usr/lib/gfc-client
	$(CP) $(PKG_BUILD_DIR)/deploy $(1)/usr/lib/gfc-client/
	if [ -d "$(PKG_BUILD_DIR)/share" ]; then $(CP) $(PKG_BUILD_DIR)/share $(1)/usr/lib/gfc-client/; fi
	# Git may store *.sh as 0644; hotplug/init invoke them directly — force +x.
	chmod -R a+X $(1)/usr/lib/gfc-client/deploy
	find $(1)/usr/lib/gfc-client/deploy -type f \( -name '*.sh' -o -path '*/cgi-bin/*' \) -exec chmod 0755 {} +

	$(INSTALL_DIR) $(1)/etc/gfc-client
	$(INSTALL_CONF) ./files/etc/gfc-client/gfc.env $(1)/etc/gfc-client/gfc.env

	# Do NOT install /etc/opkg/distfeeds.conf here — base-files owns that path
	# (opkg clash). OEM feeds come from image/files overlay (prepare_rootfs).

	# TCP BBR sysctl (kmod-tcp-bbr + kmod-sched selected via gfc-packages.config).
	$(INSTALL_DIR) $(1)/etc/sysctl.d
	$(INSTALL_DATA) ./files/etc/sysctl.d/12-gfc-bbr.conf $(1)/etc/sysctl.d/12-gfc-bbr.conf

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/gfc-api $(1)/etc/init.d/gfc-api
	$(INSTALL_BIN) ./files/etc/init.d/gfc-agent $(1)/etc/init.d/gfc-agent
	$(INSTALL_BIN) ./files/etc/init.d/gfc-unbound $(1)/etc/init.d/gfc-unbound
	$(INSTALL_BIN) ./files/etc/init.d/gfc-sing-box $(1)/etc/init.d/gfc-sing-box
	$(INSTALL_BIN) ./files/etc/init.d/gfc-routing $(1)/etc/init.d/gfc-routing
	$(INSTALL_BIN) ./files/etc/init.d/gfc-lan-dhcp $(1)/etc/init.d/gfc-lan-dhcp

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/93-gfc-vga-console $(1)/etc/uci-defaults/93-gfc-vga-console
	$(INSTALL_BIN) ./files/etc/uci-defaults/95-gfc-rootpt-resize $(1)/etc/uci-defaults/95-gfc-rootpt-resize
	$(INSTALL_BIN) ./files/etc/uci-defaults/96-gfc-rootfs-resize $(1)/etc/uci-defaults/96-gfc-rootfs-resize
	$(INSTALL_BIN) ./files/etc/uci-defaults/97-gfc-oem-root-password $(1)/etc/uci-defaults/97-gfc-oem-root-password
	$(INSTALL_BIN) ./files/etc/uci-defaults/98-gfc-network-ports $(1)/etc/uci-defaults/98-gfc-network-ports
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-gfc-firstboot $(1)/etc/uci-defaults/99-gfc-firstboot

	$(INSTALL_DIR) $(1)/etc/hotplug.d/net
	$(INSTALL_BIN) ./files/etc/hotplug.d/net/99-gfc-tun $(1)/etc/hotplug.d/net/99-gfc-tun
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./files/etc/hotplug.d/iface/99-gfc-dnsmasq $(1)/etc/hotplug.d/iface/99-gfc-dnsmasq

	# Port-80 activation assets (uhttpd). Do NOT install /www/index.html here —
	# luci-base owns that path (opkg clash). 99-gfc-firstboot / 99-gfc-portal
	# overwrite it at runtime from $DEPLOY/www/index.html.
	$(INSTALL_DIR) $(1)/www/cgi-bin $(1)/www/gfc
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/deploy/immortalwrt/www/cgi-bin/gfc-activation $(1)/www/cgi-bin/gfc-activation
	$(CP) $(PKG_BUILD_DIR)/deploy/immortalwrt/www/gfc/* $(1)/www/gfc/
endef

define Package/gfc-client/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
mkdir -p /etc/gfc-client /var/lib/gfc-client/state /var/lib/gfc-client/rules /var/lib/gfc-client/dns-lists /var/log/gfc-client
/etc/init.d/unbound stop 2>/dev/null || true
/etc/init.d/unbound disable 2>/dev/null || true
/etc/init.d/gfc-api enable
/etc/init.d/gfc-agent enable
/etc/init.d/gfc-unbound enable
/etc/init.d/gfc-sing-box enable
/etc/init.d/gfc-routing enable
/etc/init.d/gfc-lan-dhcp enable
if [ -f /var/lib/gfc-client/state/config_bundle.json ]; then
	gfc-bootstrap --reapply >/tmp/gfc-bootstrap.log 2>&1 || echo "gfc-bootstrap reapply failed; keeping existing config" >>/tmp/gfc-bootstrap.log
else
	gfc-bootstrap >/tmp/gfc-bootstrap.log 2>&1 || true
fi
exit 0
endef

$(eval $(call BuildPackage,gfc-client))
