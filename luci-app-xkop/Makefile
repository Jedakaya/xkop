include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-xkop

PKG_VERSION := $(if $(XKOP_VERSION),$(XKOP_VERSION),0.$(shell date +%d%m%Y))

PKG_RELEASE:=1

LUCI_TITLE:=LuCI для xkop
LUCI_DEPENDS:=+luci-base +xkop
LUCI_PKGARCH:=all

PKG_LICENSE:=MIT
PKG_MAINTAINER:=Jedakaya

include $(TOPDIR)/feeds/luci/luci.mk

$(eval $(call BuildPackage,$(PKG_NAME)))
