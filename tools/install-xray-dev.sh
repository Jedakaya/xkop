#!/bin/sh
# Puts the engine on a router for bench work. Runs ON the router.
#
# This is not the installer the project will ship - that one lives in a package
# and knows about rollback, see docs/install.md. This is the short path to a
# working Xray on a test router, and it keeps only the rules that were bought
# with real failures:
#
#   - the archive is downloaded into /tmp, which is RAM, so a failure costs no
#     flash and leaves the router exactly as it was;
#   - free space is checked AFTER the download and BEFORE the install, against
#     the real size of the file rather than a constant;
#   - the geo files are left in the archive: they are most of its 19 MB and the
#     stats bench does not need them;
#   - the result is proved by running it, not by the exit code of the copy.
#
# Usage (on the router):
#   sh install-xray-dev.sh                 в /usr/bin/xray
#   XRAY_TARGET=/tmp/xray sh install-xray-dev.sh    без единого байта на флэш
#   XRAY_VERSION=v26.7.28 sh install-xray-dev.sh
#   XRAY_ASSET=Xray-linux-mips32le.zip sh install-xray-dev.sh

set -eu

# Newest release XTLS does not mark as prerelease. Everything after it is
# published as prerelease, so "latest" from the API stops here - and taking a
# prerelease blindly is exactly what docs/install.md forbids.
XRAY_VERSION=${XRAY_VERSION:-v26.3.27}
XRAY_TARGET=${XRAY_TARGET:-/usr/bin/xray}
WORK=/tmp/xkop-xray-install

log() { echo "== $*"; }
die() { echo "!! $*" >&2; exit 1; }

# OpenWrt states its own architecture, and it is more precise than uname: on a
# little endian mips router uname -m still answers "mips", which would fetch a
# big endian binary that cannot run.
detect_asset() {
    [ -n "${XRAY_ASSET:-}" ] && { echo "$XRAY_ASSET"; return; }

    local arch=""
    [ -r /etc/os-release ] && arch=$(. /etc/os-release 2> /dev/null && echo "${OPENWRT_ARCH:-}")
    [ -n "$arch" ] || arch=$(uname -m)

    case "$arch" in
        x86_64*)        echo "Xray-linux-64.zip" ;;
        i386*|i686*)    echo "Xray-linux-32.zip" ;;
        aarch64*)       echo "Xray-linux-arm64-v8a.zip" ;;
        arm_arm926*|armv5*)   echo "Xray-linux-arm32-v5.zip" ;;
        arm_mpcore*|armv6*)   echo "Xray-linux-arm32-v6.zip" ;;
        arm*)           echo "Xray-linux-arm32-v7a.zip" ;;
        mipsel*|mipsle*) echo "Xray-linux-mips32le.zip" ;;
        mips64el*)      echo "Xray-linux-mips64le.zip" ;;
        mips64*)        echo "Xray-linux-mips64.zip" ;;
        mips*)          echo "Xray-linux-mips32.zip" ;;
        riscv64*)       echo "Xray-linux-riscv64.zip" ;;
        loongarch64*)   echo "Xray-linux-loong64.zip" ;;
        *)              echo "" ;;
    esac
}

asset=$(detect_asset)
[ -n "$asset" ] || die "архитектуру определить не удалось, задайте XRAY_ASSET"

base="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION"

rm -rf "$WORK"
mkdir -p "$WORK"

log "$XRAY_VERSION, $asset"

curl -fsSL --max-time 300 -o "$WORK/$asset" "$base/$asset" \
    || die "не удалось скачать $base/$asset"

# The checksum is published next to the archive. A truncated download on a
# flaky link produces a file that unzips into a binary which does not run, and
# the reason for that is much harder to see later.
if curl -fsSL --max-time 30 -o "$WORK/$asset.dgst" "$base/$asset.dgst" 2> /dev/null; then
    expected=$(awk '/^SHA2-256=/ {print $2}' "$WORK/$asset.dgst")
    actual=$(sha256sum "$WORK/$asset" | awk '{print $1}')
    if [ -n "$expected" ] && [ "$expected" != "$actual" ]; then
        die "контрольная сумма не сошлась: ждали $expected, получили $actual"
    fi
    log "контрольная сумма сошлась"
else
    log "контрольная сумма недоступна, продолжаю без неё"
fi

unzip -o -q "$WORK/$asset" xray -d "$WORK" || die "не удалось распаковать xray из архива"
[ -s "$WORK/xray" ] || die "в архиве нет файла xray"

size_kb=$(( ($(wc -c < "$WORK/xray") + 1023) / 1024 ))
target_dir=$(dirname "$XRAY_TARGET")
free_kb=$(df -k "$target_dir" | awk 'NR==2 {print $4}')

log "нужно ${size_kb} КБ, свободно ${free_kb} КБ в $target_dir"

# Space is checked against the real size, not a constant: fixed thresholds
# refused routers that had room, which is a failure invented out of nothing.
if [ "$free_kb" -lt "$size_kb" ]; then
    die "не хватает места в $target_dir; попробуйте XRAY_TARGET=/tmp/xray, это RAM"
fi

chmod +x "$WORK/xray"
cp "$WORK/xray" "$XRAY_TARGET.new"
mv "$XRAY_TARGET.new" "$XRAY_TARGET"
rm -rf "$WORK"

log "проверка запуском:"
"$XRAY_TARGET" version | head -n 1
