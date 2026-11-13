#!/bin/sh
# shellcheck shell=ash
# Bounded provider input must never replace a working cache with partial data.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
XKOP_LIB_DIR="$ROOT/xkop/files/usr/lib/xkop"
. "$XKOP_LIB_DIR/subscription.sh"
lab=$(mktemp -d)
trap 'rm -rf "$lab"' EXIT
failed=0 total=0
check() {
    total=$((total + 1))
    if [ "$2" = "$3" ]; then echo "ok   $1"; else
        echo "FAIL $1: expected=$2 actual=$3"; failed=$((failed + 1))
    fi
}
export XKOP_CONFIG=xkop
uci() {
    case "$*" in
        *subscription_max_bytes) echo 1024 ;;
        *) return 1 ;;
    esac
}
subscription_hwid() { echo fixture; }
subscription_device_model() { echo fixture; }
curl() {
    local target=- headers='' arg
    printf 'called\n' >> "$lab/calls"
    while [ "$#" -gt 0 ]; do
        arg="$1"; shift
        case "$arg" in
            -o) target="$1"; shift ;;
            -D) headers="$1"; shift ;;
        esac
    done
    [ -z "$headers" ] || printf 'HTTP/1.1 200 OK\r\n\r\n' > "$headers"
    if [ "$target" = - ]; then cat "$lab/body"; else cp "$lab/body" "$target"; fi
    return 0
}
printf 'small payload' > "$lab/body"
subscription_fetch_one https://fixture.invalid ua "$lab/out" "$lab/headers"
check 'small response accepted' 0 "$?"
check 'small response intact' 'small payload' "$(cat "$lab/out")"
head_binary=$(command -v head)
"$head_binary" -c 8192 /dev/zero > "$lab/body"
subscription_fetch_one https://fixture.invalid ua "$lab/out" "$lab/headers"
check 'oversized response rejected' 1 "$?"
check 'oversized response not retained' no "$(test -f "$lab/out" && echo yes || echo no)"
gzip -c "$lab/body" > "$lab/large.gz"
cp "$lab/large.gz" "$lab/before.gz"
subscription_decompress_gzip "$lab/large.gz"
check 'oversized decompressed response rejected' 1 "$?"
check 'failed decompression preserves source' 0 "$(cmp -s "$lab/large.gz" "$lab/before.gz"; echo $?)"
printf '\037\213broken' > "$lab/broken.gz"
subscription_decompress_gzip "$lab/broken.gz"
check 'corrupt gzip rejected' 1 "$?"
printf 'valid small response' > "$lab/plain"
gzip -c "$lab/plain" > "$lab/small.gz"
subscription_decompress_gzip "$lab/small.gz"
check 'valid gzip accepted' 0 "$?"
check 'valid gzip content intact' 0 "$(cmp -s "$lab/plain" "$lab/small.gz"; echo $?)"
printf 'small payload' > "$lab/body"
head() { command head "$@"; return 1; }
subscription_fetch_one https://fixture.invalid ua "$lab/out" "$lab/headers"
check 'output write failure rejected' 1 "$?"
unset -f head
before=$(wc -l < "$lab/calls" | tr -d ' ')
export XKOP_SUBSCRIPTION_DEADLINE=1
subscription_fetch_one https://fixture.invalid ua "$lab/out" "$lab/headers"
check 'expired overall deadline fails' 1 "$?"
check 'expired overall deadline makes no request' "$before" "$(wc -l < "$lab/calls" | tr -d ' ')"
echo "$((total - failed))/$total"
[ "$failed" -eq 0 ]
