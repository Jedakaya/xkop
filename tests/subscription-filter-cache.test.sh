#!/bin/sh
# Changed subscription keywords constrain cached nodes immediately, even offline.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
XKOP_LIB_DIR="$ROOT/xkop/files/usr/lib/xkop"
. "$XKOP_LIB_DIR/subscription.sh"
lab=$(mktemp -d)
trap 'rm -rf "$lab"' EXIT
XKOP_CONFIG=xkop XKOP_RUN_DIR="$lab/run" XKOP_CACHE_DIR="$lab/cache"
XKOP_SOURCE_SUFFIXES='=' XKOP_AGENT_DEFAULT=fixture
mkdir -p "$XKOP_RUN_DIR" "$XKOP_CACHE_DIR/main"
keyword=$(jq -nr '"\u0411\u0435\u043b\u044b\u0439"')
jq '.[0:2] | .[0].remarks="\u0411\u0435\u043b\u044b\u0439 list N3" | .[1].remarks="ordinary"' \
    "$ROOT/tests/fixtures/subscription/happ.json" > "$lab/payload"
filter_include='' filter_exclude='' offline=0
uci() {
    case "$*" in
        *main.url) echo https://fixture.invalid ;;
        *main.enabled) echo 1 ;;
        *main.include) printf '%s' "$filter_include" ;;
        *main.exclude) printf '%s' "$filter_exclude" ;;
        *main.update_interval) echo 1h ;;
        *) return 1 ;;
    esac
}
subscription_ids() { echo main; }
subscription_config_list() { :; }
# The fixture is plain JSON; network and compression are covered separately.
subscription_decompress_gzip() { return 0; }
subscription_fetch_one() {
    echo fetch >> "$lab/fetches"
    [ "$offline" = 0 ] || return 1
    cp "$lab/payload" "$3"; : > "$4"
}
subscription_update() {
    XKOP_SUBSCRIPTION_DEADLINE=$(( $(subscription_clock) + 60 ))
    subscription_update_locked "$1"
}
log_info() { :; }; log_warn() { :; }
failed=0
check() {
    if [ "$2" = "$3" ]; then echo "ok $1"; else
        echo "FAIL $1: expected=$2 actual=$3"; failed=$((failed+1))
    fi
}
tags() { subscription_pool_all | jq -c '[.[].tag]'; }
subscription_update main
check 'initial full cached pool' 2 "$(subscription_pool main | jq length)"
subscription_due main
check 'unchanged fresh filters do not refetch' 1 "$?"
filter_exclude="$keyword"
check 'exclude immediately applies to cached Happ names' '["ordinary"]' "$(tags)"
subscription_due main
check 'changed exclude schedules refresh despite fresh cache' 0 "$?"
offline=1
subscription_update_all startup
check 'offline refresh never revives excluded nodes' '["ordinary"]' "$(tags)"
check 'offline refresh preserves stored last-good pool' 2 "$(jq length "$XKOP_CACHE_DIR/main/pool.json")"
offline=0
subscription_update_all startup
check 'successful refresh stores filtered result' '["ordinary"]' "$(jq -c '[.[].tag]' "$XKOP_CACHE_DIR/main/pool.json")"
subscription_due main
check 'successful refresh acknowledges current filters' 1 "$?"
filter_exclude='' filter_include="$keyword"
offline=1
check 'new include never treats filtered cache as complete' '[]' "$(tags)"
subscription_update_all startup
check 'offline include cannot restore a previously excluded node' '[]' "$(tags)"
offline=0
subscription_update_all startup
check 'new include recovers its node after successful download' "[\"$keyword list N3\"]" "$(tags)"
filter_include=''
subscription_due main
check 'removing include schedules full-pool download' 0 "$?"
subscription_update_all startup
check 'removing filters restores both nodes after download' 2 "$(subscription_pool main | jq length)"
filter_exclude='ordinary'
check 'second keyword applies without another download' "[\"$keyword list N3\"]" "$(tags)"
mv() {
    case "$*" in *'/filters.json') return 1 ;; esac
    command mv "$@"
}
subscription_update main
check 'failed filter publication is reported' 1 "$?"
subscription_due main
check 'failed filter publication keeps refresh due' 0 "$?"
check 'failed filter publication cannot expose forbidden nodes' "[\"$keyword list N3\"]" "$(tags)"
check 'failed filter publication removes staging' 0 \
    "$(find "$XKOP_RUN_DIR" -maxdepth 1 -type d -name 'subscription-main.*' | wc -l | tr -d ' ')"
unset -f mv
echo "failures=$failed"
[ "$failed" = 0 ]
