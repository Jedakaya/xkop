#!/bin/sh
# Completeness gate must reject a missing architecture before publication.
set -eu
ROOT=${ROOT:-$(dirname "$0")/..}
lab=$(mktemp -d)
trap 'rm -rf "$lab"' EXIT
for format in apk ipk; do
    suffix=; [ "$format" = apk ] || suffix=-all
    for name in xkop luci-app-xkop; do printf fixture > "$lab/$name-0.2.25-r1$suffix.$format"; done
    for arch in aarch64_cortex-a53 aarch64_cortex-a72 aarch64_generic arm_cortex-a7_neon-vfpv4 arm_cortex-a9_neon mipsel_24kc mips_24kc x86_64; do
        printf fixture > "$lab/xray-xkop-26.10.31-r1-$arch.$format"
    done
done
printf installer > "$lab/install.sh"
sh "$ROOT/tools/release-complete.sh" "$lab" 0.2.25 26.10.31
test "$(jq '.assets | length' "$lab/release-manifest.json")" = 21
rm "$lab/xray-xkop-26.10.31-r1-mips_24kc.ipk"
if sh "$ROOT/tools/release-complete.sh" "$lab" 0.2.25 26.10.31; then echo 'FAIL incomplete release accepted'; exit 1; fi
echo 'ok complete APK/IPK release and missing architecture rejected'
