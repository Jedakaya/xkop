#!/bin/sh
# shellcheck shell=ash
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
XKOP_LIB_DIR="$ROOT/xkop/files/usr/lib/xkop"
lab=$(mktemp -d)
trap 'rm -rf "$lab"' EXIT
export XKOP_CACHE_DIR="$lab/cache" XKOP_RUN_DIR="$lab/run" XKOP_CONFIG=xkop
mkdir -p "$XKOP_CACHE_DIR/main" "$XKOP_RUN_DIR"
. "$XKOP_LIB_DIR/lock.sh"
. "$XKOP_LIB_DIR/subscription.sh"
log_warn() { :; }; log_info() { :; }
failed=0 total=0
check() {
    total=$((total + 1))
    if [ "$2" = "$3" ]; then echo "ok   $1"; else
        echo "FAIL $1: expected=$2 actual=$3"; failed=$((failed + 1))
    fi
}
node_limit=1 total_limit=16777216
uci() {
    case "$*" in
        *main.url) echo https://fixture.invalid ;;
        *main.enabled) echo 1 ;;
        *subscription_max_nodes) echo "$node_limit" ;;
        *subscription_total_bytes) echo "$total_limit" ;;
        *) return 1 ;;
    esac
}
export XKOP_AGENT_DEFAULT=fixture
subscription_config_list() { :; }
subscription_fetch_one() {
    printf '%s\n' "${XKOP_SUBSCRIPTION_DEADLINE:-missing}" >> "$lab/calls"
    cp "$ROOT/tests/fixtures/subscription/xray-json.json" "$3"
    : > "$4"
}
printf '[{"tag":"last-good"}]' > "$XKOP_CACHE_DIR/main/pool.json"
lock_acquire subscription-main
subscription_update main
check 'busy subscription skips duplicate fetch' no "$(test -f "$lab/calls" && echo yes || echo no)"
lock_release subscription-main
rm -f "$lab/calls"
subscription_update main
check 'node limit preserves last good cache' last-good "$(jq -r '.[0].tag' "$XKOP_CACHE_DIR/main/pool.json")"
check 'node limit gives explicit reason' resource_limit "$(jq -r .reason "$XKOP_CACHE_DIR/main/meta.json")"
check 'refresh gives shared overall deadline' no "$(grep -q missing "$lab/calls" && echo yes || echo no)"
check 'refresh releases its lock' no "$(test -d "$XKOP_RUN_DIR/lock-subscription-main" && echo yes || echo no)"
check 'refresh leaves no staging directory' 0 "$(find "$XKOP_RUN_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
before=$(wc -l < "$lab/calls" | tr -d ' ')
subscription_update '../outside' >/dev/null 2>&1
check 'invalid subscription ID rejected' 1 "$?"
check 'invalid ID makes no request' "$before" "$(wc -l < "$lab/calls" | tr -d ' ')"
node_limit=2048
mv() {
    case "$*" in *'/pool.json') return 1 ;; esac
    command mv "$@"
}
subscription_update main
check 'failed pool publication preserves last-good' last-good "$(jq -r '.[0].tag' "$XKOP_CACHE_DIR/main/pool.json")"
check 'failed pool publication is not ready' cache_write_failed "$(jq -r .reason "$XKOP_CACHE_DIR/main/meta.json")"
unset -f mv
total_limit=1024
subscription_update main
check 'aggregate byte limit preserves last-good' last-good "$(jq -r '.[0].tag' "$XKOP_CACHE_DIR/main/pool.json")"
check 'aggregate byte limit reported' resource_limit "$(jq -r .reason "$XKOP_CACHE_DIR/main/meta.json")"
total_limit=16777216
mv() {
    case "$*" in *'/meta.json') return 1 ;; esac
    command mv "$@"
}
subscription_update main
check 'metadata publication failure returned' 1 "$?"
unset -f mv
echo "$((total - failed))/$total"
[ "$failed" -eq 0 ]
