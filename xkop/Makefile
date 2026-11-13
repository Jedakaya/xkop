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
	$(INSTALL_BIN) ./files/etc/init.d/xkop-fleet $(1)/etc/init.d/xkop-fleet

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/xkop $(1)/usr/bin/xkop
	$(INSTALL_BIN) ./files/usr/bin/xkop-fleet $(1)/usr/bin/xkop-fleet

	$(INSTALL_DIR) $(1)/usr/lib/xkop
	$(CP) ./files/usr/lib/xkop/* $(1)/usr/lib/xkop/

	# Package-owned assets follow ordinary and fleet updates and their rollback.
	# Presence of this bundle does not enable the optional uhttpd instance.
	$(INSTALL_DIR) $(1)/usr/share/xkop/client-panel/cgi-bin
	$(INSTALL_DATA) ./client-panel/index.html $(1)/usr/share/xkop/client-panel/index.html
	$(INSTALL_BIN) ./client-panel/cgi-bin/* $(1)/usr/share/xkop/client-panel/cgi-bin/

	# Что обязано пережить обновление прошивки. sysupgrade сохраняет
	# /etc/config и то, что пакеты назвали в keep.d — так делают dnsmasq
	# и uhttpd. Всё наше состояние лежит вне /etc/config.
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/lib/upgrade/keep.d/xkop $(1)/lib/upgrade/keep.d/xkop

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

# Keep recovery tools installed when restoring the router DNS fails.
if [ -x /usr/bin/xkop ]; then
	/usr/bin/xkop teardown || exit 1
fi
/etc/init.d/xkop stop 2>/dev/null || exit 1

# The optional reporter must not survive package removal or replacement.
if [ -x /etc/init.d/xkop-fleet ]; then
	/etc/init.d/xkop-fleet stop 2>/dev/null || exit 1
fi

# Stop the optional listener before replacing/removing its package-owned assets.
# The activation marker is user state and survives package upgrades/rollback.
if [ -r /usr/lib/xkop/constants.sh ] && [ -r /usr/lib/xkop/service.sh ]; then
	. /usr/lib/xkop/constants.sh 2>/dev/null
	. /usr/lib/xkop/logging.sh 2>/dev/null
	. /usr/lib/xkop/service.sh 2>/dev/null
	command -v panel_remove_uhttpd >/dev/null 2>&1 && panel_remove_uhttpd
fi

exit 0
endef

$(eval $(call BuildPackage,xkop))
