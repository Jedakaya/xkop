#!/bin/sh
set -eu
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
jq -nc '["apk","ipk"] as $formats
    | ["aarch64_cortex-a53","aarch64_cortex-a72","aarch64_generic",
       "arm_cortex-a7_neon-vfpv4","arm_cortex-a9_neon","mipsel_24kc","mips_24kc","x86_64"] as $arches
    | [{tag_name:"vcomplete",assets:[$formats[] as $f | $arches[] as $a
        | {name:("xray-xkop-26.10.31-r1-"+$a+"."+$f)}]}]' > "$work/full.json"
check() {
    actual=$(jq -r --arg version 26.10.31 -f "$ROOT/tools/engine-release-source.jq" "$work/$1.json")
    [ "$actual" = "$2" ] || { echo "FAIL $1: '$actual'"; exit 1; }
    echo "ok   $1"
}
check full vcomplete
jq '.[0].assets |= map(select(.name | endswith(".apk")))' "$work/full.json" > "$work/apk-only.json"
check apk-only ''
jq '.[0].assets |= .[1:]' "$work/full.json" > "$work/missing-arch.json"
check missing-arch ''
jq '.[0].assets[0].name = "xray-xkop-26.9.9-r1-aarch64_cortex-a53.apk"' "$work/full.json" > "$work/mixed-version.json"
check mixed-version ''
jq '.[0].draft = true' "$work/full.json" > "$work/draft.json"
check draft ''
