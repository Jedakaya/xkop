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
PKG_VERSION:=26.7.28
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

XRAY_HASH_Xray-linux-64:=8195d909f1109b8f3d99eefe401a3c451d7bf4af71f24d3815420f77e5dd2a40
XRAY_HASH_Xray-linux-32:=87ee3f90e48fe4b930c69ba4bcf7376a44e9b6caebbe8d4479b3b795c8ff3fa2
XRAY_HASH_Xray-linux-arm64-v8a:=f5698bb218ada3b4022db26fafc39601c5f53b46b19eb76c9616325985807501
XRAY_HASH_Xray-linux-arm32-v7a:=a23cae6991ea1224e4e3381cae4ada8c3d5afc438a851ab0b2eda2f391dc4072
XRAY_HASH_Xray-linux-arm32-v6:=8a6e29f36d16a25ea4c80ddabf1cca79f9d06e73a7a2170dc1b5726d6b8afda5
XRAY_HASH_Xray-linux-arm32-v5:=f11efbba5174b0f676d332153a60f261e896415de072e0553440ba9cee7b0c06
XRAY_HASH_Xray-linux-mips32le:=4779e1afba7dea12c64a72380f1d9737a12359f354014625a7f9d96f8d31e3fa
XRAY_HASH_Xray-linux-mips32:=aec600118fd1e7ee42e8d5e8d5c82cc5e8139e82ff1da029e9b81b7170fc028c
XRAY_HASH_Xray-linux-mips64le:=5e5f28532e8bde40fdb3dd3133487119147a39dd6e611ea53b830c7dc10d6ad1
XRAY_HASH_Xray-linux-mips64:=f2da91e931b0df28ca8a8c71d8c0a8f17aa2be6f9798e6874d46d66197aa2fd9
XRAY_HASH_Xray-linux-riscv64:=aba048426d8a3381751e53c54af6f84c9f831d881dc28aed77bd7b40bc1814c0

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
