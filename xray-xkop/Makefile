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
# The version is pinned deliberately. Blind updates to the newest release would
# hand a regression to the whole fleet at once - v26.4.15 and v26.4.17 had a
# routing one - so the checked version is raised by hand, after it has run on
# our own router. Same reasoning as install.md.

PKG_NAME:=xray-xkop
PKG_VERSION:=26.3.27
PKG_RELEASE:=1

PKG_MAINTAINER:=Jedakaya
PKG_LICENSE:=MPL-2.0
PKG_LICENSE_FILES:=LICENSE

XKOP_TARGET_ARCH ?= $(ARCH)

# OpenWrt architecture -> the asset XTLS publishes for it. The mips split is
# the one that matters: "uname -m" says "mips" for both endiannesses, and a big
# endian binary on a little endian router does not run at all.
XRAY_ASSET_x86_64:=Xray-linux-64
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

XRAY_HASH_Xray-linux-64:=23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae
XRAY_HASH_Xray-linux-32:=d1eeb0d9a9106eefd286fbb73595c2dfe1c48c56aa91ba1c9aefe04f188d0927
XRAY_HASH_Xray-linux-arm64-v8a:=4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c
XRAY_HASH_Xray-linux-arm32-v7a:=c7265ae13c63ca0241a037df4ef960ad37938c8a67d984cc08834b2cfdf5654b
XRAY_HASH_Xray-linux-arm32-v6:=0c6e751e2bba3f3ff09a793dd6a6bc45fd6fd89f49b49dfc0cf6d922dc123bec
XRAY_HASH_Xray-linux-arm32-v5:=0da9a632e15e82504831f61bf6b46c21e3081bcc79ad46bdc16e7dc2f0dc9088
XRAY_HASH_Xray-linux-mips32le:=fe1ded07a64fe0a406c6c1089f09b6c2999fc2309509ca4c98d93469c0cbf9df
XRAY_HASH_Xray-linux-mips32:=a562f2edbdabc0f1a17eee2226fa9f710e6b61c2d5e2bf3435157b5ce40b1c67
XRAY_HASH_Xray-linux-mips64le:=7f660cb026ab9251bd70c30ecf383243d133eb098c57287bf3f4e0c01c66c898
XRAY_HASH_Xray-linux-mips64:=40432515e6d98033b3934a38dc4f2dac1801e80e3da88c3d230310d17e79dca7
XRAY_HASH_Xray-linux-riscv64:=627ea5870b6fd05d95b7f4ceb5a54d7f2664dd075b30a7ac46ee9a6f9653d6f8

# The OpenWrt architecture is "family_cpu", and the family is what decides the
# binary: aarch64_cortex-a53 and aarch64_generic take the same one.
XKOP_ARCH_FAMILY:=$(firstword $(subst _, ,$(XKOP_TARGET_ARCH)))
XRAY_ASSET:=$(XRAY_ASSET_$(XKOP_ARCH_FAMILY))

PKG_SOURCE:=$(XRAY_ASSET).zip
PKG_SOURCE_URL:=https://github.com/XTLS/Xray-core/releases/download/v$(PKG_VERSION)
PKG_HASH:=$(XRAY_HASH_$(XRAY_ASSET))

PKGARCH:=$(XKOP_TARGET_ARCH)

include $(INCLUDE_DIR)/package.mk

define Package/xray-xkop
	SECTION:=net
	CATEGORY:=Network
	TITLE:=Xray-core for xkop
	URL:=https://github.com/XTLS/Xray-core
	DEPENDS:=@!(TARGET_uml)
	PROVIDES:=xray-core
	CONFLICTS:=xray-core
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
