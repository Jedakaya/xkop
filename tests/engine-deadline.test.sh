#!/bin/sh
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_STATE_DIR="$work"
. "$ROOT/xkop/files/usr/lib/xkop/service.sh"
echo 0 > "$work/time"
echo 0 > "$work/calls"
service_monotime() { cat "$work/time"; }
engine_answers() {
 echo $(($(cat "$work/time") + 2)) > "$work/time"
 echo $(($(cat "$work/calls") + 1)) > "$work/calls"
 return 1
}
sleep() { echo $(($(cat "$work/time") + $1)) > "$work/time"; }
engine_wait 8
[ "$(cat "$work/time")" -le 8 ] || { echo 'FAIL readiness exceeded deadline'; exit 1; }
[ "$(cat "$work/calls")" = 3 ] || exit 1
echo 'ok engine readiness uses elapsed time'
