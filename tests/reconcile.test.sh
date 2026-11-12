#!/bin/sh
# A network repair failure must not lose a required engine reload.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_STATE_DIR="$work" XKOP_RUN_DIR="$work" XKOP_CONFIG_PATH="$work/config.json"
. "$ROOT/xkop/files/usr/lib/xkop/service.sh"
service_wan_ready() { return 0; }; lists_present() { return 0; }
lists_subnets_ready() { return 0; }
subscription_update_all() { : > "$work/updates"; }; userlist_update_all() { :; }; lists_subnets_update() { : > "$work/optional-sources"; }
config_generate() { [ "$GEN" != 0 ] || : > "$work/config-reload.pending"; return "$GEN"; }
config_generated_ok() { [ "$1" = 0 ] || [ "$1" = 2 ]; }
nft_present() { return 0; }; nft_apply() { return "$NFT_FAIL"; }; nft_routing_rule() { return "${RULE_FAIL:-0}"; }
config_uci_get() { :; }; engine_answers() { return 0; }; service_proxy_ready() { return 0; }
service_finish_start() { return 0; }
GEN=0 NFT_FAIL=1
service_reconcile; first=$?
GEN=2 NFT_FAIL=0
service_reconcile; second=$?
if [ "$first" != 1 ] || [ "$second" != 2 ]; then
 echo "FAIL required reload lost after repair failure: $first/$second"
 exit 1
fi
echo 'ok   required reload survives repair failure'
[ ! -f "$work/optional-sources" ] || { echo 'FAIL optional sources delayed the core reload'; exit 1; }
echo 'ok   core reload precedes optional network sources'

rm -f "$work/config-reload.pending"
service_reconcile || exit 1
[ -f "$work/optional-sources" ] || { echo 'FAIL optional sources never refreshed'; exit 1; }
echo 'ok   optional sources refresh after the core is ready'

: > "$work/wan-reprobe.pending"
service_proxy_ready() { return 1; }
service_reconcile; missing=$?
[ "$missing" = 1 ] || { echo 'FAIL late WAN restarted an engine still missing its proxy pool'; exit 1; }
service_proxy_ready() { return 0; }
rm -f "$work/updates"
service_reconcile; reprobe=$?
[ "$reprobe" = 2 ] || { echo 'FAIL engine started before WAN was not reprobed'; exit 1; }
[ ! -f "$work/updates" ] || { echo 'FAIL subscription download delayed cached WAN recovery'; exit 1; }
rm -f "$work/wan-reprobe.pending"
echo 'ok   late WAN reprobes the engine even with an unchanged cache'

RULE_FAIL=1
rm -f "$work/updates"
service_reconcile; no_route=$?
[ "$no_route" = 1 ] && [ ! -f "$work/updates" ] || { echo 'FAIL network downloads preceded policy routing repair'; exit 1; }
RULE_FAIL=0
echo 'ok   policy routing is repaired before network downloads'

GEN=3
config_validate() { return 0; }
echo '{}' > "$XKOP_CONFIG_PATH"
if service_reconcile; then echo 'FAIL busy config writer discarded the updated cache'; exit 1; fi
echo 'ok   busy config writer requires another reconciliation'
GEN=2

subscription_update_all() { : > "$work/service-stopped"; }
rm -f "$work/optional-sources"
if service_reconcile; then echo 'FAIL cancelled reconciliation reported ready'; exit 1; fi
[ ! -f "$work/optional-sources" ] || { echo 'FAIL stopped service applied late updates'; exit 1; }
echo 'ok   stop cancels application after a pending download'
