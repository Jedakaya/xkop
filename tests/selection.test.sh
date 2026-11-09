#!/bin/sh
# Manual selection must be effective before the first health probe.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
JQ=${JQ:-jq}
LIB="$ROOT/xkop/files/usr/lib/xkop"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
check() {
    if [ "$2" = "$3" ]; then echo "ok   $1"; else
        echo "FAIL $1: expected '$2', got '$3'"; failed=$((failed + 1))
    fi
}
XKOP_STATE_DIR="$work/state"
XKOP_RUN_DIR="$work/run"
XKOP_CONFIG_PATH="$work/config.json"
XKOP_LIB_DIR="$LIB"
mkdir -p "$XKOP_STATE_DIR" "$XKOP_RUN_DIR"
log_info() { :; }; log_warn() { :; }; log_error() { :; }
. "$LIB/config.sh"
. "$LIB/nodes.sh"
config_settings_json() { "$JQ" '.settings' "$ROOT/tests/fixtures/config/with-pool.json"; }
subscription_pool_all() { "$JQ" '.pool' "$ROOT/tests/fixtures/config/with-pool.json"; }
config_bindings_json() { "$JQ" '.bindings' "$ROOT/tests/fixtures/config/with-pool.json"; }
config_validate() { "$JQ" -e '.routing.balancers | length == 1' "$1" >/dev/null; }
API_FAIL=0
nodes_api() {
    [ "$API_FAIL" = 0 ] || return 1
    if [ "$1" = adrules ]; then cp "$2" "$work/live.json"; fi
    return 0
}

printf 'DE-Frankfurt-1' > "$(nodes_manual_marker)"
input=$(config_input_json)
check 'persistent manual choice reaches generator' DE-Frankfurt-1 "$(printf '%s' "$input" | "$JQ" -r '.manual_pin')"
printf '%s' "$input" | "$JQ" -f "$LIB/config.jq" > "$XKOP_CONFIG_PATH"
check 'startup fallback is the exact manual node' DE-Frankfurt-1 "$("$JQ" -r '.routing.balancers[0].fallbackTag' "$XKOP_CONFIG_PATH")"
check 'startup cannot select a different node before override' true "$("$JQ" '[.outbounds[].tag] as $tags | .routing.balancers[0].selector | all(. as $prefix | $tags | all(startswith($prefix) | not))' "$XKOP_CONFIG_PATH")"
check 'manual startup keeps observing the whole pool' 2 "$("$JQ" '.burstObservatory.subjectSelector | length' "$XKOP_CONFIG_PATH")"

# Active outbounds can outlive a node removed from the subscription cache.
"$JQ" '.outbounds += [{tag:"__xkop_manual__old",protocol:"freedom"}]' "$XKOP_CONFIG_PATH" > "$work/active.json"
mv "$work/active.json" "$XKOP_CONFIG_PATH"

out=$(nodes_select NL-Amsterdam-2)
check 'manual switch succeeds' true "$(printf '%s' "$out" | "$JQ" -r '.ok')"
check 'manual switch persists startup routing for respawn' NL-Amsterdam-2 "$("$JQ" -r '.routing.balancers[0].fallbackTag' "$XKOP_CONFIG_PATH")"
check 'manual switch applies routing without restart' NL-Amsterdam-2 "$("$JQ" -r '.routing.balancers[0].fallbackTag' "$work/live.json" 2>/dev/null)"
check 'manual selector excludes old active nodes missing from cache' true "$("$JQ" '[.outbounds[].tag] as $tags | .routing.balancers[0].selector | all(. as $prefix | $tags | all(startswith($prefix) | not))' "$XKOP_CONFIG_PATH")"

API_FAIL=1
out=$(nodes_select auto)
check 'failed auto switch is reported' false "$(printf '%s' "$out" | "$JQ" -r '.ok')"
check 'failed auto switch preserves manual marker' NL-Amsterdam-2 "$(cat "$(nodes_manual_marker)")"
check 'failed auto switch preserves startup config' NL-Amsterdam-2 "$("$JQ" -r '.routing.balancers[0].fallbackTag' "$XKOP_CONFIG_PATH")"
API_FAIL=0
out=$(nodes_select auto)
check 'auto switch succeeds' true "$(printf '%s' "$out" | "$JQ" -r '.ok')"
check 'auto switch restores full selector' 2 "$("$JQ" '.routing.balancers[0].selector | length' "$work/live.json" 2>/dev/null)"
check 'auto switch removes manual marker' false "$([ -f "$(nodes_manual_marker)" ] && echo true || echo false)"

# A vanished tag must not be installed as a fallback.
config_input_json missing | "$JQ" -f "$LIB/config.jq" > "$work/missing.json"
check 'missing manual node returns to normal pool' direct "$("$JQ" -r '.routing.balancers[0].fallbackTag' "$work/missing.json")"

# Prefix selectors must never accidentally select a similarly named node.
"$JQ" '.manual_pin = "NL-Amsterdam-2" | .pool += [{tag:"__xkop_manual__evil",outbound:{tag:"__xkop_manual__evil",protocol:"freedom"}}]' "$ROOT/tests/fixtures/config/with-pool.json" |
    "$JQ" -f "$LIB/config.jq" > "$work/prefix.json"
check 'subscription names cannot collide with manual selector' true "$("$JQ" '[.outbounds[].tag] as $tags | .routing.balancers[0].selector | all(. as $prefix | $tags | all(startswith($prefix) | not))' "$work/prefix.json")"
: > "$XKOP_RUN_DIR/bootstrap.pending"
out=$(nodes_select NL-Amsterdam-2)
check 'selection waits for full routing during bootstrap' false "$(printf '%s' "$out" | "$JQ" -r '.ok')"
[ "$failed" -eq 0 ]
