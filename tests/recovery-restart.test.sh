#!/bin/sh
# A failed restart must not discard the only recovery worker.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_RUN_DIR="$work" XKOP_STATE_DIR="$work"
. "$ROOT/xkop/files/usr/lib/xkop/lock.sh"
. "$ROOT/xkop/files/usr/lib/xkop/service.sh"
XKOP_RECOVERY_PID="$work/recovery.pid"
log_info() { :; }; log_warn() { :; }; log_error() { :; }
service_reconcile() { return 2; }
service_restart_engine() {
 if [ ! -f "$work/first-failed" ]; then : > "$work/first-failed"; return 1; fi
 : > "$work/retried"
 : > "$work/service-stopped"
 return 0
}
recovery_start
i=0
while [ ! -f "$work/retried" ] && [ "$i" -lt 12 ]; do sleep 1; i=$((i+1)); done
: > "$work/service-stopped"
recovery_stop
[ -f "$work/retried" ] || { echo 'FAIL failed restart left no automatic recovery'; exit 1; }
echo 'ok   failed restart is retried automatically'
