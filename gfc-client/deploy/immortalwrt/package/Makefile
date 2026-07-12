include $(TOPDIR)/rules.mk

PKG_NAME:=gfc-client
PKG_VERSION:=1.1.0
PKG_RELEASE:=5
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

	$(INSTALL_DIR) $(1)/etc/gfc-client
	$(INSTALL_CONF) ./files/etc/gfc-client/gfc.env $(1)/etc/gfc-client/gfc.env

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/gfc-api $(1)/etc/init.d/gfc-api
	$(INSTALL_BIN) ./files/etc/init.d/gfc-agent $(1)/etc/init.d/gfc-agent
	$(INSTALL_BIN) ./files/etc/init.d/gfc-unbound $(1)/etc/init.d/gfc-unbound
	$(INSTALL_BIN) ./files/etc/init.d/gfc-sing-box $(1)/etc/init.d/gfc-sing-box
	$(INSTALL_BIN) ./files/etc/init.d/gfc-routing $(1)/etc/init.d/gfc-routing

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-gfc-firstboot $(1)/etc/uci-defaults/99-gfc-firstboot
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
if [ -f /var/lib/gfc-client/state/config_bundle.json ]; then
	gfc-bootstrap --reapply >/tmp/gfc-bootstrap.log 2>&1 || echo "gfc-bootstrap reapply failed; keeping existing config" >>/tmp/gfc-bootstrap.log
else
	gfc-bootstrap >/tmp/gfc-bootstrap.log 2>&1 || true
fi
exit 0
endef

$(eval $(call BuildPackage,gfc-client))
