#!/bin/sh
# Package revisions differ between opkg and apk.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
extract() { sed -n "/^$2()/,/^}/p" "$1" | sed "1s/^$2()/$3()/"; }
{
    extract "$ROOT/install.sh" installed_version i_version
    extract "$ROOT/install.sh" engine_version_core i_core
    extract "$ROOT/xkop/files/usr/lib/xkop/update.sh" update_installed_version u_version
    extract "$ROOT/xkop/files/usr/lib/xkop/update.sh" update_engine_version_core u_core
} > "$work/functions.sh"
. "$work/functions.sh"
apk() { printf 'xkop-0.2.20-r1 noarch {x} (MIT) [installed]\n'; }
opkg() { printf 'xkop - 0.2.20-1\n'; }
failed=0
check() {
    if [ "$2" = "$3" ]; then echo "ok   $1";
    else echo "FAIL $1: expected '$2', got '$3'"; failed=$((failed + 1)); fi
}
for manager in apk opkg; do
    if [ "$manager" = apk ]; then PKG_IS_APK=1; else PKG_IS_APK=0; fi
    update_pkg_format() { [ "$PKG_IS_APK" = 1 ] && printf apk || printf ipk; }
    # update_installed_version uses command discovery, so isolate that choice.
    sed 's/if command -v apk > \/dev\/null 2>\&1; then/if [ "$PKG_IS_APK" = 1 ]; then/' "$work/functions.sh" > "$work/selected.sh"
    . "$work/selected.sh"
    check "installer $manager revision" 0.2.20 "$(i_version)"
    check "updater $manager revision" 0.2.20 "$(u_version)"
done
for version in 26.10.31-1 26.10.31-r1 26.10.31-12 26.10.31-r12 26.10.31; do
    check "installer engine $version" 26.10.31 "$(i_core "$version")"
    check "updater engine $version" 26.10.31 "$(u_core "$version")"
done
[ "$failed" -eq 0 ]
