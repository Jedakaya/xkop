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
PKG_VERSION:=26.9.9
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

XRAY_HASH_Xray-linux-64:=1eb9175d0f0a8f8149c9230a7fc5ae66ce332ed20a53155ce61fe62e3f58b7df
XRAY_HASH_Xray-linux-32:=52a825a06d77f6e2d0d72d8d873b1fd277ae503ac9a2aedb112f4f5db0e347e0
XRAY_HASH_Xray-linux-arm64-v8a:=3e38d72dfc5eb65c91df0e5583e9b6676c32232041da47de6ae73946b526d66c
XRAY_HASH_Xray-linux-arm32-v7a:=5b2a9e2767c0197f7bd41c2db133f91440e845771e621178e0fd2b8520228e5f
XRAY_HASH_Xray-linux-arm32-v6:=259583689327b21e696e0837b4f6a57dc3c2ef07d63edec64be7ec54eb356f19
XRAY_HASH_Xray-linux-arm32-v5:=09628b8657037fcf155ed2498ba54b5a2c778212ae2193042fe54d789a26c039
XRAY_HASH_Xray-linux-mips32le:=e572d2cdd819318383460443140898e6117e8e0da5f0c359b25f6c890b8d81a2
XRAY_HASH_Xray-linux-mips32:=4b9838c570f283d7104e0c775df3562a4f12f33c06e6c77ddcf2319845bf47ba
XRAY_HASH_Xray-linux-mips64le:=fe3d2d9c696d9256e0e139e4ad4c5da164b232a1a11cf7183830003bd0de75b4
XRAY_HASH_Xray-linux-mips64:=2e43c5cfb27a0e2af0570b6f1d09491a3dd3a1e9670cd87d64ff9d7539d49cac
XRAY_HASH_Xray-linux-riscv64:=032663d3ef60278dc40e225c6fff8514ed850473e8845337bad08af9badbb449

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
