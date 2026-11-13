#!/bin/sh
# Validate the complete supported release set before making a draft public.
set -eu
folder=$1 version=$2 engine=$3
list="$folder/.release-assets.jsonl"
trap 'rm -f "$list"' EXIT
: > "$list"
record() {
    [ -s "$1" ] || { echo "missing/empty release asset: $1" >&2; return 1; }
    hash=$(sha256sum "$1" | awk '{print $1}')
    bytes=$(wc -c < "$1" | tr -d ' ')
    jq -nc --arg name "${1##*/}" --arg hash "$hash" --argjson size "$bytes" \
        '{name:$name,sha256:$hash,size:$size}' >> "$list"
}
package() {
    count=0 selected=
    for file in "$folder/$1-r1$2" "$folder/$1-1$2"; do
        [ -f "$file" ] || continue
        count=$((count + 1)); selected=$file
    done
    [ "$count" = 1 ] || { echo "missing/ambiguous release package: $1$2" >&2; return 1; }
    record "$selected"
}
for format in apk ipk; do
    suffix=; [ "$format" = apk ] || suffix=-all
    for name in xkop luci-app-xkop; do package "$name-$version" "$suffix.$format"; done
    for arch in aarch64_cortex-a53 aarch64_cortex-a72 aarch64_generic arm_cortex-a7_neon-vfpv4 arm_cortex-a9_neon mipsel_24kc mips_24kc x86_64; do
        package "xray-xkop-$engine" "-$arch.$format"
    done
done
record "$folder/install.sh"
jq -s --arg version "$version" --arg engine "$engine" \
    '{schema:1,version:$version,engine:$engine,assets:.}' "$list" > "$folder/release-manifest.json.new"
mv "$folder/release-manifest.json.new" "$folder/release-manifest.json"
