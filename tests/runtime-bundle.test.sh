#!/bin/sh
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_RUN_DIR="$work/run" XKOP_STATE_DIR="$work/state" XKOP_CACHE_DIR="$work/cache"
XKOP_CONFIG_PATH="$work/config.json"
mkdir -p "$XKOP_RUN_DIR" "$XKOP_STATE_DIR"
. "$ROOT/xkop/files/usr/lib/xkop/service.sh"
log_info() { :; }; log_warn() { :; }; log_error() { :; }
cron_install() { :; }; service_check_requirements() { return 0; }
service_br_netfilter_disable() { :; }; service_sync_time() { :; }
service_wan_ready() { return 0; }; lists_present() { return 0; }
config_generated_ok() { [ "$1" = 0 ] || [ "$1" = 2 ]; }
config_validate() { jq -e '.mode' "$1" >/dev/null; }
config_generate() {
 [ "$bad" = 0 ] || return 1
 printf '{"mode":"%s"}' "$mode" > "$XKOP_CONFIG_PATH"
}
config_uci_get() { case "$2" in dns_mode) echo "$mode";; *) echo 0;; esac; }
nft_apply() {
 [ "$nft_bad" = 0 ] || return 1
 echo "$mode" > "$XKOP_RUN_DIR/nft-active.rules"
 cp "$XKOP_RUN_DIR/nft-active.rules" "$work/firewall"
}
nft_replace() { cp "$1" "$work/firewall"; }
nft_routing_rule() { return 0; }
dnsmasq_configure() { echo fakeip > "$work/dns"; }
dnsmasq_restore() { echo off > "$work/dns"; }
dnsmasq_protection() { :; }; panel_present() { return 1; }
failed=0
check() { if [ "$1" = "$2" ]; then echo "ok $3"; else echo "FAIL $3: $1 != $2"; failed=$((failed+1)); fi; }
mode=off bad=0 nft_bad=0
service_prepare || exit 1
check no "$([ -s "$(service_runtime_path)" ] && echo yes || echo no)" 'unstarted candidate does not replace last-good'
# Simulate a confirmed process loading the exact prepared snapshot.
engine_answers() { return 0; }
cp "$XKOP_CONFIG_PATH" "$XKOP_RUN_DIR/starting-config.json"
service_runtime_confirm
mode=fakeip bad=1
service_prepare
check off "$(cat "$work/dns")" 'failed off-to-fakeip keeps DNS'
check off "$(cat "$work/firewall")" 'failed off-to-fakeip keeps firewall'
rm -f "$work/dns" "$work/firewall" "$XKOP_CONFIG_PATH"
service_prepare
check off "$(cat "$work/dns" 2>/dev/null)" 'cold boot restores last-good DNS'
check off "$(jq -r .mode "$XKOP_CONFIG_PATH" 2>/dev/null)" 'cold boot restores last-good JSON'
bad=0
service_prepare || exit 1
cp "$XKOP_CONFIG_PATH" "$XKOP_RUN_DIR/starting-config.json"
service_runtime_confirm
mode=off bad=1
service_prepare
check fakeip "$(cat "$work/dns")" 'failed fakeip-to-off keeps DNS'
check fakeip "$(cat "$work/firewall")" 'failed fakeip-to-off keeps firewall'
bad=0 nft_bad=1
service_prepare
check fakeip "$(jq -r .mode "$XKOP_CONFIG_PATH")" 'failed nft after valid JSON restores coherent runtime'
nft_bad=0 mode=off
service_prepare || exit 1
cp "$XKOP_CONFIG_PATH" "$XKOP_RUN_DIR/starting-config.json"
engine_answers() { return 1; }
service_runtime_confirm
check fakeip "$(jq -r .config.mode "$(service_runtime_path)")" 'nonstarting valid candidate preserves last-good'
service_runtime_failed
check fakeip "$(jq -r .mode "$XKOP_CONFIG_PATH")" 'failed launch restores engine JSON'
check fakeip "$(cat "$work/dns")" 'failed launch restores DNS'
service_prepare
check fakeip "$(jq -r .mode "$XKOP_CONFIG_PATH")" 'recovery restart loads last-good before retrying candidate'
exit "$failed"
