include $(TOPDIR)/rules.mk

# The engine, repackaged.
#
# XTLS publishes official binaries for every architecture, so nothing is
# compiled here: the release archive is downloaded, the binary is taken out of
# it, and it is wrapped into a package. That is the whole job, and it is why
# taking over delivery of the engine costs the project so little - see
# docs/install.md.
#
# One package per architecture, built from one SDK. The architecture is passed
# in rather than taken from the SDK: the contents are a prebuilt binary, and
# what has to match the router is the metadata, not the toolchain that wrapped
# it.
#
#   make package/xray-xkop/compile XKOP_TARGET_ARCH=aarch64_cortex-a53
#
# The version is pinned deliberately: a blind jump to the newest release would
# hand a regression to the whole fleet at once, so it is raised by hand.
#
# What it is NOT pinned by is the "prerelease" flag. That rule was here, and it
# was wrong: XTLS marks every release since v26.3.27 as preliminary - all of
# them, for months on end - so following the flag meant standing still while
# the clients people actually use moved on. Checked against the API, not
# assumed: v26.7.28, v26.7.11, v26.6.27, v26.5.9 are all flagged, v26.3.27 is
# the last one that is not.

PKG_NAME:=xray-xkop
PKG_VERSION:=26.10.31
PKG_RELEASE:=1

PKG_MAINTAINER:=Jedakaya
PKG_LICENSE:=MPL-2.0
PKG_LICENSE_FILES:=LICENSE

XKOP_TARGET_ARCH ?= $(ARCH)

# OpenWrt architecture -> the asset XTLS publishes for it. The mips split is
# the one that matters: "uname -m" says "mips" for both endiannesses, and a big
# endian binary on a little endian router does not run at all.
# The family is the part before the underscore, and for x86_64 that is "x86":
# the architecture string splits into "x86" and "64" like every other one, and
# the sixty-four goes where the CPU name goes for the rest of them. Missing
# that made this the only architecture of eight that did not build.
XRAY_ASSET_x86:=Xray-linux-64
XRAY_ASSET_i386:=Xray-linux-32
XRAY_ASSET_aarch64:=Xray-linux-arm64-v8a
XRAY_ASSET_arm:=Xray-linux-arm32-v7a
XRAY_ASSET_armv5:=Xray-linux-arm32-v5
XRAY_ASSET_armv6:=Xray-linux-arm32-v6
XRAY_ASSET_mipsel:=Xray-linux-mips32le
XRAY_ASSET_mips:=Xray-linux-mips32
XRAY_ASSET_mips64el:=Xray-linux-mips64le
XRAY_ASSET_mips64:=Xray-linux-mips64
XRAY_ASSET_riscv64:=Xray-linux-riscv64

XRAY_HASH_Xray-linux-64:=e4bd9119f50ae7c41658b1abd0679ae06f98bd864a2907ff33f2f2cf7081b214
XRAY_HASH_Xray-linux-32:=4064a12c7712f28f0a85082be3564c088f7861f2220ddb5e4de409c91837511d
XRAY_HASH_Xray-linux-arm64-v8a:=1811c8f1da0c3b6dc707ebaf1c8390e987ba39859a8f0a7aadd8526157f2ec8d
XRAY_HASH_Xray-linux-arm32-v7a:=2387f55239ee7799fd67d5382e79f589c1da07a97d993e86b058f2290b8e456b
XRAY_HASH_Xray-linux-arm32-v6:=28c27bbd262bcc751e2e07115f47ce50d79611289e19e8b499b3065497b0e1ec
XRAY_HASH_Xray-linux-arm32-v5:=1a80facc22919d5deca01931f8afa3953870f21f6b1c34ad2657892002696403
XRAY_HASH_Xray-linux-mips32le:=7f3e56ea73f2e2ce12556ba3720e8894abd89c17aec5c70ea70ae6f48552cfb5
XRAY_HASH_Xray-linux-mips32:=45a84c48da48e7f7663c4c0030977ba0d56ba24a5c855de6a1d898be904e16db
XRAY_HASH_Xray-linux-mips64le:=9d326d3fd242fa020f60d2832f1c85ef0f821e6098f127b158c51c5288f0a184
XRAY_HASH_Xray-linux-mips64:=e15e8a9a795977b60618344e260b33590d75c8834fb015104ee1063e5386dccf
XRAY_HASH_Xray-linux-riscv64:=1159825b0d448fc7f56ca6f12e4872de2bf80a6639964819e0827fa0ad1283e8

# The OpenWrt architecture is "family_cpu", and the family is what decides the
# binary: aarch64_cortex-a53 and aarch64_generic take the same one.
XKOP_ARCH_FAMILY:=$(firstword $(subst _, ,$(XKOP_TARGET_ARCH)))
XRAY_ASSET:=$(XRAY_ASSET_$(XKOP_ARCH_FAMILY))

# An unknown architecture stops the build here, where the reason is one line.
# Left to run on, it downloads a file called ".zip" and fails on a checksum,
# which is where the previous failure actually pointed.
ifeq ($(XRAY_ASSET),)
$(error Неизвестная архитектура $(XKOP_TARGET_ARCH): нет соответствия файлу релиза XTLS)
endif

PKG_SOURCE:=$(XRAY_ASSET).zip
PKG_SOURCE_URL:=https://github.com/XTLS/Xray-core/releases/download/v$(PKG_VERSION)
PKG_HASH:=$(XRAY_HASH_$(XRAY_ASSET))

include $(INCLUDE_DIR)/package.mk

define Package/xray-xkop
	SECTION:=net
	CATEGORY:=Network
	TITLE:=Xray-core for xkop
	URL:=https://github.com/XTLS/Xray-core
	DEPENDS:=@!(TARGET_uml)
	PROVIDES:=xray-core
	CONFLICTS:=xray-core
	# Внутри блока, а не снаружи: Package/Default присваивает
	# PKGARCH:=$$(ARCH_PACKAGES) безусловно и затирает всё, что задано выше
	# по файлу. Снаружи оно выглядело рабочим, а восемь пакетов уходили
	# в релиз с arch: x86_64 и на роутере отвергались как «uninstallable».
	PKGARCH:=$(XKOP_TARGET_ARCH)
endef

define Package/xray-xkop/description
	Official Xray-core binary from XTLS releases, wrapped for OpenWrt.
	Not built from source: XTLS publishes binaries for every architecture.
endef

# The archive is a zip, not a tarball, so the default unpacking does not apply.
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	unzip -o $(DL_DIR)/$(PKG_SOURCE) -d $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
endef

# Only the binary. geoip.dat and geosite.dat from the archive are left behind
# on purpose: together they are around thirty megabytes, and xkop uses a
# ninety kilobyte list of its own - see docs/build.md.
define Package/xray-xkop/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/xray $(1)/usr/bin/xray

	$(INSTALL_DIR) $(1)/usr/share/xray
endef

$(eval $(call BuildPackage,xray-xkop))
