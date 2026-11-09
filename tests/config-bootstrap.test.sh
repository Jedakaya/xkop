#!/bin/sh
# A first start must not require the list its own SOCKS tunnel will download.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_RUN_DIR="$work/run" XKOP_STATE_DIR="$work/state"
XKOP_CONFIG_PATH="$work/config.json" XKOP_LIB_DIR="$ROOT/xkop/files/usr/lib/xkop"
mkdir -p "$XKOP_RUN_DIR" "$XKOP_STATE_DIR" "$work/assets"
. "$XKOP_LIB_DIR/config.sh"
log_info() { :; }; log_warn() { :; }; log_error() { :; }
config_input_json() {
    jq --arg log "$work/access.log" '.settings.access_log_path=$log | .settings += {
        dns_mode:"fakeip", dns_server:"8.8.8.8", dns_type:"doh", dns_extra:[], sniff_excluded:[]}' \
        "$ROOT/tests/fixtures/config/with-pool.json"
}
lists_present() { [ -f "$work/assets/ready" ]; }
engine_answers() { return 1; }
config_validate() {
    if lists_present; then return 0; fi
    jq -e '[.. | strings | select(startswith("geosite:"))] | length == 0' "$1" >/dev/null
}
printf DE-Frankfurt-1 > "$XKOP_STATE_DIR/manualpin"
if ! config_generate; then echo 'FAIL cold start requires missing geosite'; exit 1; fi
jq -e '.inbounds | length==1 and .[0].tag=="probe-in" and .[0].listen=="127.0.0.1"' "$XKOP_CONFIG_PATH" >/dev/null || exit 1
jq -e '.routing.rules[0].outboundTag=="DE-Frankfurt-1" and (.routing.balancers|length)==0
    and .dns==null and .fakedns==null and .burstObservatory==null' "$XKOP_CONFIG_PATH" >/dev/null || exit 1
[ -f "$XKOP_RUN_DIR/bootstrap.pending" ] || { echo 'FAIL no bootstrap pending marker'; exit 1; }
echo 'ok   cold start creates only a pinned loopback tunnel without geosite'
if command -v "${XRAY:-xray}" >/dev/null 2>&1; then
    XRAY_LOCATION_ASSET="$work/assets" "${XRAY:-xray}" run -test -c "$XKOP_CONFIG_PATH" > "$work/engine.log" 2>&1 || {
        cat "$work/engine.log"; exit 1;
    }
    echo 'ok   actual engine accepts bootstrap with an empty asset directory'
fi
cp "$XKOP_CONFIG_PATH" "$work/bootstrap.json"
: > "$work/assets/ready"
config_generate || exit 1
jq -e 'any(.inbounds[]; .tag=="tproxy-in") and (.dns!=null)' "$XKOP_CONFIG_PATH" >/dev/null || exit 1
[ -f "$XKOP_RUN_DIR/bootstrap.pending" ] || { echo 'FAIL full config is ready before engine confirmation'; exit 1; }
echo 'ok   full config is restored after lists arrive, pending engine confirmation'
rm -f "$work/assets/ready" "$XKOP_RUN_DIR/bootstrap.pending"
cp "$XKOP_CONFIG_PATH" "$work/full.json"
engine_answers() { return 0; }
if config_generate; then echo 'FAIL replaced a working engine with bootstrap'; exit 1; fi
cmp -s "$XKOP_CONFIG_PATH" "$work/full.json" || exit 1
echo 'ok   losing an asset does not replace an already working full engine'
echo '{"outbounds":[],"routing":{"balancers":[]}}' > "$XKOP_CONFIG_PATH"
if ! config_generate; then echo 'FAIL an answering empty engine prevents first tunnel bootstrap'; exit 1; fi
jq -e '.routing.rules[0].outboundTag=="DE-Frankfurt-1"' "$XKOP_CONFIG_PATH" >/dev/null || exit 1
echo 'ok   an empty answering engine can adopt newly cached nodes for bootstrap'
