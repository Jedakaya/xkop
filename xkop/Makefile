include $(TOPDIR)/rules.mk

PKG_NAME:=xkop

PKG_VERSION := $(if $(XKOP_VERSION),$(XKOP_VERSION),0.$(shell date +%d%m%Y))

PKG_RELEASE:=1

PKG_MAINTAINER:=Jedakaya
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

# The engine is not a package dependency on purpose: xkop ships its own Xray
# package and the installer decides which version lands, see docs/install.md.
#
# jq here is the default OpenWrt build, which has no oniguruma and therefore no
# test/match/gsub. That is on purpose - jq-full would drag the regex library
# onto routers that count free flash in megabytes - and the jq programs under
# files/usr/lib/xkop are written without regular expressions.
define Package/xkop
	SECTION:=net
	CATEGORY:=Network
	DEPENDS:=+curl +jq +gzip +coreutils-base64 +nftables +kmod-nft-tproxy +bind-dig
	CONFLICTS:=podkop luci-app-passwall luci-app-passwall2 https-dns-proxy nextdns
	TITLE:=Traffic router on Xray-core
	URL:=https://github.com/Jedakaya/xkop
	PKGARCH:=all
endef

define Package/xkop/description
	Traffic router for OpenWrt. Blocked destinations go through the tunnel,
	everything else goes direct.
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/xkop/conffiles
/etc/config/xkop
endef

define Package/xkop/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/xkop $(1)/etc/config/xkop

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/xkop $(1)/etc/init.d/xkop

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/xkop $(1)/usr/bin/xkop

	$(INSTALL_DIR) $(1)/usr/lib/xkop
	$(CP) ./files/usr/lib/xkop/* $(1)/usr/lib/xkop/

	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(PKG_VERSION)/g' $(1)/usr/lib/xkop/constants.sh
endef

# bind-dig и список конфликтов взяты у podkop, где они куплены отказами.
#
# dig нужен Канарейке: busybox nslookup не даёт задать тип запроса и не всегда
# отличает NXDOMAIN от пустого ответа, а весь смысл Канарейки в том, чтобы
# различать «имени нет» и «подсунули адрес».
#
# https-dns-proxy и nextdns переписывают dnsmasq под себя. Стоять рядом они
# могут только до первого перезапуска, после чего резолвер оказывается чужим,
# и выяснять это на живом роутере дорого.

define Package/xkop/prerm
#!/bin/sh

/etc/init.d/xkop stop 2>/dev/null

exit 0
endef

$(eval $(call BuildPackage,xkop))
