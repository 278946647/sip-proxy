include $(TOPDIR)/rules.mk

PKG_NAME:=gfc-client
PKG_VERSION:=1.1.0
PKG_RELEASE:=1
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)
GFC_CLIENT_SRC ?= $(abspath $(CURDIR)/../../..)

include $(INCLUDE_DIR)/package.mk

define Package/gfc-client
  SECTION:=net
  CATEGORY:=Network
  TITLE:=GFC client box management agent
  DEPENDS:=+ca-bundle +ip-full +nftables +dnsmasq-full +sing-box +mosdns +sqlite3-cli +autossh
endef

define Package/gfc-client/description
GFC client management backend and web UI for ImmortalWrt/OpenWrt based boxes.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(GFC_CLIENT_SRC)/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) build-openwrt GOOS=linux GOARCH=$(GO_ARCH) CGO_ENABLED=0
endef

define Package/gfc-client/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/bin/gfc-api $(1)/usr/bin/gfc-api
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/bin/gfc-agent $(1)/usr/bin/gfc-agent
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/bin/gfc-bootstrap $(1)/usr/bin/gfc-bootstrap

	$(INSTALL_DIR) $(1)/usr/lib/gfc-client
	$(CP) $(PKG_BUILD_DIR)/deploy $(1)/usr/lib/gfc-client/
	if [ -d "$(PKG_BUILD_DIR)/share" ]; then $(CP) $(PKG_BUILD_DIR)/share $(1)/usr/lib/gfc-client/; fi
	if [ -d "$(PKG_BUILD_DIR)/web-static" ]; then $(CP) $(PKG_BUILD_DIR)/web-static $(1)/usr/lib/gfc-client/web; fi

	$(INSTALL_DIR) $(1)/etc/gfc-client
	$(INSTALL_CONF) ./files/etc/gfc-client/gfc.env $(1)/etc/gfc-client/gfc.env

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/gfc-api $(1)/etc/init.d/gfc-api
	$(INSTALL_BIN) ./files/etc/init.d/gfc-agent $(1)/etc/init.d/gfc-agent
	$(INSTALL_BIN) ./files/etc/init.d/gfc-mosdns $(1)/etc/init.d/gfc-mosdns
	$(INSTALL_BIN) ./files/etc/init.d/gfc-sing-box $(1)/etc/init.d/gfc-sing-box
	$(INSTALL_BIN) ./files/etc/init.d/gfc-routing $(1)/etc/init.d/gfc-routing
endef

define Package/gfc-client/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
mkdir -p /etc/gfc-client /var/lib/gfc-client/state /var/lib/gfc-client/rules /var/lib/gfc-client/dns-lists /var/log/gfc-client
/etc/init.d/gfc-api enable
/etc/init.d/gfc-agent enable
/etc/init.d/gfc-mosdns enable
/etc/init.d/gfc-sing-box enable
/etc/init.d/gfc-routing enable
if [ -f /var/lib/gfc-client/state/config_bundle.json ]; then
	gfc-bootstrap --reapply >/tmp/gfc-bootstrap.log 2>&1 || echo "gfc-bootstrap reapply failed; keeping existing config" >>/tmp/gfc-bootstrap.log
else
	gfc-bootstrap >/tmp/gfc-bootstrap.log 2>&1 || true
fi
exit 0
endef

$(eval $(call BuildPackage,gfc-client))
