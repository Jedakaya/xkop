#!/bin/sh
# Bootstrap must not redirect clients into an engine without their inbounds.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_RUN_DIR="$work" XKOP_STATE_DIR="$work" XKOP_CACHE_DIR="$work/cache"
XKOP_CONFIG_PATH="$work/config.json"
. "$ROOT/xkop/files/usr/lib/xkop/service.sh"
# Bundle persistence is exercised by runtime-bundle.test.sh.
service_runtime_save() { return 0; }
service_dns_apply() { return 0; }
log_warn() { :; }; log_error() { :; }
log_info() { :; }; log_warn() { :; }; log_error() { :; }
cron_install() { :; }; service_check_requirements() { return 0; }
service_br_netfilter_disable() { :; }; service_sync_time() { :; }
service_wan_ready() { return 0; }; lists_present() { return 1; }
lists_subnets_ready() { return 0; }
config_generate() { : > "$work/bootstrap.pending"; echo '{}' > "$XKOP_CONFIG_PATH"; return 0; }
config_generated_ok() { [ "$1" = 0 ] || [ "$1" = 2 ]; }
config_uci_get() { [ "$2" != dns_mode ] || echo fakeip; }
nft_present() { return 0; }; nft_apply() { echo nft >> "$work/unsafe"; }
nft_routing_rule() { echo rule >> "$work/unsafe"; }
nft_clear() { echo clear >> "$work/order"; }
dnsmasq_restore() { echo restore >> "$work/order"; }
dnsmasq_protection_clear() { :; }
dnsmasq_cleanup() { dnsmasq_protection_clear; dnsmasq_restore; }
dnsmasq_configure() { echo dns >> "$work/unsafe"; }
dnsmasq_protection() { echo protection >> "$work/unsafe"; }
panel_present() { return 1; }
service_prepare || exit 1
[ ! -f "$work/unsafe" ] || { echo 'FAIL bootstrap enables interception or DNS before full config'; exit 1; }
grep -q restore "$work/order" || exit 1
echo 'ok   bootstrap clears stale interception and restores Xkop-managed DNS'
engine_answers() { return 0; }; service_finish_start() { return 0; }
lists_update() { echo fetch >> "$work/downloads"; return 1; }
subscription_update_all() { :; }; service_proxy_ready() { return 1; }
config_generate() { return 2; }
cp "$XKOP_CONFIG_PATH" "$work/bootstrap-config.json"
if service_reconcile; then echo 'FAIL bootstrap reported ready without lists'; exit 1; else result=$?; fi
[ "$result" = 1 ] && [ ! -f "$work/unsafe" ] || { echo 'FAIL bootstrap downloads enable interception'; exit 1; }
echo 'ok   a failed list download stays pending without client interception'
lists_present() { return 0; }
config_generate() { echo '{"full":true}' > "$XKOP_CONFIG_PATH"; return 0; }
if service_reconcile; then echo 'FAIL full config needs no engine reload'; exit 1; else result=$?; fi
[ "$result" = 2 ] && [ ! -f "$work/unsafe" ] || { echo 'FAIL full interception precedes loading the full config'; exit 1; }
echo 'ok   full configuration is loaded before enabling client interception'
engine_process_running() { return 0; }; nft_routing_ready() { return 0; }
subscription_pool_all() { echo '[]'; }
status=$(service_status_json)
printf '%s' "$status" | jq -e '.lists_pending==true and .routing_ready==false and .state!="работает"' >/dev/null || exit 1
echo 'ok   bootstrap is shown as waiting for lists, never as working routing'
: > "$XKOP_RUN_DIR/service-stopped"
engine_process_running() { return 1; }; engine_answers() { return 1; }
status=$(service_status_json)
printf '%s' "$status" | jq -e '.lists_pending==false and .state=="остановлен"' >/dev/null || {
    echo 'FAIL explicitly stopped bootstrap is still shown as loading'; exit 1;
}
echo 'ok   an explicit stop is shown as stopped even with cached bootstrap state'
dnsmasq_verify() { return 1; }
status=$(service_status_json)
printf '%s' "$status" | jq -e '.dns_ready==false and .routing_ready==false and .state=="локальный DNS не отвечает"' >/dev/null || exit 1
echo 'ok   dead local DNS is exposed in status'
dnsmasq_verify() { return 0; }
rm -f "$XKOP_RUN_DIR/service-stopped" "$XKOP_RUN_DIR/bootstrap.pending"
engine_process_running() { return 0; }; engine_answers() { return 0; }
service_proxy_ready() { return 0; }; lists_subnets_ready() { return 1; }
status=$(service_status_json)
printf '%s' "$status" | jq -e '.lists_pending==true and .community_lists_pending==true and .routing_ready==false and .state=="догружает комьюнити-списки"' >/dev/null || exit 1
echo 'ok   missing community lists remain visible after the full engine starts'
