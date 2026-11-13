#!/bin/sh
# Boot must use the cache and reconcile dependencies after the engine starts.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_STATE_DIR="$work/state"
XKOP_RUN_DIR="$work/run"
XKOP_CACHE_DIR="$work/cache"
XKOP_CONFIG_PATH="$work/config.json"
mkdir -p "$XKOP_STATE_DIR" "$XKOP_RUN_DIR" "$XKOP_CACHE_DIR"
. "$ROOT/xkop/files/usr/lib/xkop/service.sh"
# Bundle persistence is exercised by runtime-bundle.test.sh.
service_runtime_save() { return 0; }
service_dns_apply() { return 0; }
log_warn() { :; }; log_error() { :; }
failed=0
check() {
 if [ "$2" = "$3" ]; then echo "ok   $1"; else
  echo "FAIL $1: expected '$2', got '$3'"; failed=$((failed+1))
 fi
}
log_info() { :; }; log_warn() { :; }; log_error() { :; }
cron_install() { :; }; service_check_requirements() { return 0; }
service_br_netfilter_disable() { :; }; service_sync_time() { :; }
lists_present() { return 0; }; lists_update() { echo lists >> "$work/network"; }
lists_subnets_ready() { return 0; }
lists_refresh_background() { echo background >> "$work/network"; }
userlist_update_all() { echo userlists >> "$work/network"; }
subscription_update_all() { echo subscription >> "$work/network"; }
subscription_pool_all() { echo '[]'; }
config_generate() { return 2; }
config_generated_ok() { [ "$1" = 0 ] || [ "$1" = 2 ]; }
nft_apply() { return 0; }; nft_present() { return 0; }
config_uci_get() { [ "$2" != dns_mode ] || echo fakeip; }
dnsmasq_configure() { :; }; dnsmasq_protection() { :; }
panel_present() { return 1; }
service_wan_ready() { return 1; }
service_prepare
check 'prepare with cache makes no network requests' false "$([ -e "$work/network" ] && echo true || echo false)"
check 'startup before WAN records a required reprobe' true "$([ -f "$XKOP_RUN_DIR/wan-reprobe.pending" ] && echo true || echo false)"
rm -f "$XKOP_RUN_DIR/wan-reprobe.pending"

engine_wait() { return 0; }; nodes_keep() { :; }
service_finish_start() { return 0; }
lock_run() { shift; "$@"; }
subscription_retry_failed() { :; }
recovery_start() { echo started > "$work/reconcile"; }
service_started_check
sleep 1
check 'answering metrics still trigger dependency reconciliation' started "$(cat "$work/reconcile" 2>/dev/null)"
service_finish_start() { return 1; }
log_error() { : > "$work/false-engine-error"; }
service_started_check
check 'busy startup confirmation is not a false engine failure' false "$([ -f "$work/false-engine-error" ] && echo true || echo false)"
service_finish_start() { return 0; }

rm -f "$work/network" "$work/reconcile"
service_wan_ready() { return 1; }
service_on_wan_up
check 'WAN-down event performs no downloads' false "$([ -e "$work/network" ] && echo true || echo false)"
check 'WAN-down event starts no reconciliation' false "$([ -e "$work/reconcile" ] && echo true || echo false)"

engine_process_running() { return 0; }; engine_answers() { return 0; }
service_wan_ready() { return 0; }; nft_routing_ready() { return 0; }
service_proxy_expected() { return 0; }
subscription_pool_all() { echo '[{"tag":"ready-in-cache"}]'; }
config_bindings_json() { echo '[{"channel":{"type":"subscription"}}]'; }
printf '{"routing":{"balancers":[]},"outbounds":[]}' > "$XKOP_CONFIG_PATH"
status=$(service_status_json)
check 'empty active pool is not reported as working' true "$(printf '%s' "$status" | jq '.state != "работает"')"
printf '{"routing":{"balancers":[{}]},"burstObservatory":{"subjectSelector":["node"]}}' > "$XKOP_CONFIG_PATH"
: > "$XKOP_RUN_DIR/config-reload.pending"
status=$(service_status_json)
check 'new file awaiting engine load is not reported as working' true "$(printf '%s' "$status" | jq '.config_pending == true and .routing_ready == false and .state != "работает"')"
[ "$failed" = 0 ]
