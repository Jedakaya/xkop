#!/bin/sh
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_RUN_DIR="$work" XKOP_STATE_DIR="$work"
. "$ROOT/xkop/files/usr/lib/xkop/lock.sh"
. "$ROOT/xkop/files/usr/lib/xkop/service.sh"
XKOP_RECOVERY_PID="$work/recovery.pid"
log_info() { :; }; log_warn() { :; }
service_reconcile() { : > "$work/began"; sleep 3; return 2; }
service_restart_engine() { : > "$work/restarted"; }
recovery_start
i=0
while [ ! -f "$work/began" ] && [ "$i" -lt 5 ]; do sleep 1; i=$((i+1)); done
[ -f "$work/began" ] || { echo 'FAIL worker did not start'; exit 1; }
: > "$work/service-stopped"
recovery_stop
sleep 4
[ ! -f "$work/restarted" ] || { echo 'FAIL worker restarted an explicitly stopped service'; exit 1; }
[ ! -f "$work/recovery.pid" ] || { echo 'FAIL stopped worker kept its pidfile'; exit 1; }
echo 'ok   stopping during reconciliation cannot restart the service'
