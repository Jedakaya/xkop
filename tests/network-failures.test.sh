#!/bin/sh
# Fault injection around the actual networking functions; no host mutations.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
LIB="$ROOT/xkop/files/usr/lib/xkop"
. "$LIB/constants.sh"
XKOP_RUN_DIR="$work/run" XKOP_STATE_DIR="$work/state" XKOP_CACHE_DIR="$work/cache"
XKOP_CONFIG_PATH="$work/config.json"
mkdir -p "$XKOP_RUN_DIR" "$XKOP_STATE_DIR"
log_info() { :; }; log_warn() { :; }; log_error() { :; }
failed=0
check() { if "$@"; then echo "ok $*"; else echo "FAIL $*"; failed=$((failed+1)); fi; }
. "$LIB/nft.sh"
config_uci_get() { case "$2" in dns_mode) echo fakeip;; esac; }
subscription_config_list() { echo br-lan; }
nft_routed_addresses() { echo 198.18.0.0/15; }
nft_routing_rule() { return 0; }
nft() {
 case "$1" in
 delete) rm -f "$work/table";;
 list) test -f "$work/table";;
 -f) cat > "$work/transaction"; return 1;;
 esac
}
: > "$work/table"
# Uses nft.sh here; the later mock tests service_prepare without touching networking.
# shellcheck disable=SC2218
nft_apply >/dev/null 2>&1
check test -f "$work/table"
check grep -q '^delete table inet ' "$work/transaction"
nft() { cat > "$work/submitted"; return 0; }
if nft_replace "$work/missing"; then
 echo 'FAIL unreadable nft candidate was submitted'; failed=$((failed+1))
fi
check test ! -f "$work/submitted"
. "$LIB/nodes.sh"
subscription_pool_all() { echo '[{"tag":"test","outbound":{"settings":{"vnext":[{"address":"192.0.2.1","port":443}]}}}]'; }
curl() { echo 0.000000; return 28; }
echo '{"test":17}' > "$(nodes_rtt_path)"
nodes_measure_rtt
nodes_selection_json() { echo '{"ok":true,"selection":"auto"}'; }
nodes_json '' '{"observatory":{"nodes":[{"tag":"test","state":"dead","delay_ms":null}]}}' > "$work/nodes"
check jq -e '.nodes[0].reachable == false and .nodes[0].delay_ms == null' "$work/nodes"
. "$LIB/service.sh"
cron_install() { :; }; service_check_requirements() { return 0; }
service_br_netfilter_disable() { :; }; service_sync_time() { :; }
service_wan_ready() { return 0; }; lists_present() { return 0; }
config_generate() { return 1; }
config_generated_ok() { [ "$1" = 0 ] || [ "$1" = 2 ]; }
nft_apply() { echo wrong > "$work/wrong"; }
dnsmasq_configure() { echo wrong > "$work/wrong"; }
dnsmasq_restore() { :; }; dnsmasq_protection() { :; }; panel_present() { return 1; }
echo '{"inbounds":[]}' > "$XKOP_CONFIG_PATH"
service_prepare >/dev/null 2>&1
check test ! -f "$work/wrong"
exit "$failed"
