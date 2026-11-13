#!/bin/sh
# Failed initial community downloads must keep recovery alive without restarts.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_STATE_DIR="$work" XKOP_RUN_DIR="$work" XKOP_CONFIG_PATH="$work/config.json"
. "$ROOT/xkop/files/usr/lib/xkop/service.sh"
# Bundle persistence is exercised by runtime-bundle.test.sh.
service_runtime_save() { echo '{}' > "$(service_runtime_path)"; }
service_dns_apply() { return 0; }
log_warn() { :; }; log_error() { :; }
service_wan_ready() { return 0; }; lists_present() { return 0; }
subscription_update_all() { :; }; userlist_update_all() { :; }
lists_subnets_update() { echo attempt >> "$work/attempts"; }
lists_subnets_ready() { [ -f "$work/subnets-present" ]; }
config_generate() { return 2; }; config_generated_ok() { [ "$1" = 2 ]; }
nft_present() { return 0; }; nft_apply() { echo applied >> "$work/nft"; }
nft_routing_rule() { return 0; }; config_uci_get() { :; }
engine_answers() { return 0; }; service_proxy_ready() { return 0; }
service_finish_start() { :; }; log_warn() { :; }
service_reconcile; rc=$?
[ "$rc" = 1 ] && [ ! -f "$work/startup-lists-checked" ] || {
    echo 'FAIL missing community caches were accepted as completed startup'; exit 1;
}
echo 'ok   failed initial community download keeps recovery pending'
# Also repair the false completion marker left by an earlier version.
: > "$work/startup-lists-checked"
service_reconcile; rc=$?
[ "$rc" = 1 ] && [ "$(wc -l < "$work/attempts" | tr -d ' ')" = 2 ] || exit 1
echo 'ok   a stale completion marker cannot suppress missing-cache retries'
# Partial files may change routing while another category is still absent.
config_generate() { return 0; }; config_generated_ok() { [ "$1" = 0 ] || [ "$1" = 2 ]; }
service_reconcile; rc=$?
[ "$rc" = 2 ] && [ ! -f "$work/startup-lists-checked" ] || exit 1
echo 'ok   partial cache improvements request a reload and retain missing-list retries'
rm -f "$work/nft"
config_generate() { return 2; }
: > "$work/subnets-present"
service_reconcile; rc=$?
[ "$rc" = 0 ] && [ -f "$work/startup-lists-checked" ] || exit 1
[ ! -f "$work/nft" ] || { echo 'FAIL unchanged cache retry reapplied routing'; exit 1; }
echo 'ok   successful retry completes recovery without restarting unchanged routing'
