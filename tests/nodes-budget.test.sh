#!/bin/sh
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_RUN_DIR="$work"
. "$ROOT/xkop/files/usr/lib/xkop/nodes.sh"
echo 0 > "$work/clock"
# Advance only the scheduler's clock; no actual network or lengthy sleeps.
nodes_clock() {
 now=$(cat "$work/clock")
 echo $((now+10)) > "$work/clock"
 echo "$now"
}
subscription_pool_all() {
 jq -nc '[range(0;12) | {tag:(tostring),outbound:{settings:{vnext:[{address:"192.0.2.1",port:443}]}}}]'
}
curl() { mktemp "$work/probed.XXXXXX" >/dev/null; printf 0.010000; }
nodes_measure_rtt
count=$(find "$work" -name 'probed.*' | wc -l | tr -d ' ')
[ "$count" = 2 ] || { echo "FAIL total RTT deadline ignored: $count probes"; exit 1; }
nodes_selection_json() { echo '{"selection":"auto"}'; }
printf '{"measured_at":1,"samples":{"old":17}}' > "$(nodes_rtt_path)"
nodes_json '[{"tag":"old"}]' '{"observatory":{"nodes":[{"tag":"old","state":"dead","delay_ms":null}]}}' \
 | jq -e '.nodes[0] | .reachable == false and .rtt_status == "stale" and .delay_ms == null' >/dev/null || exit 1
echo 'ok RTT scheduling respects total budget and expires old successes'
