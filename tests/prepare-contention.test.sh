#!/bin/sh
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_RUN_DIR="$work" XKOP_STATE_DIR="$work"
. "$ROOT/xkop/files/usr/lib/xkop/lock.sh"
. "$ROOT/xkop/files/usr/lib/xkop/service.sh"
XKOP_RECOVERY_PID="$work/recovery.pid"
XKOP_LOCK_WAIT=0
log_info() { :; }; log_warn() { :; }
cron_install() { : > "$work/cron"; }
service_prepare() { : > "$work/prepared"; }
service_reconcile() { service_prepare; }
lock_acquire work || exit 1
: > "$work/service-stopped"
service_prepare_serialized; result=$?
[ "$result" = 75 ] && [ ! -f "$work/prepared" ] || { echo 'FAIL busy prepare did not defer safely'; exit 1; }
[ ! -f "$work/service-stopped" ] && [ -f "$work/cron" ] || { echo 'FAIL startup recovery left disabled'; exit 1; }
lock_release work
i=0
while [ ! -f "$work/prepared" ] && [ "$i" -lt 6 ]; do sleep 1; i=$((i+1)); done
[ -f "$work/prepared" ] || { echo 'FAIL deferred preparation did not recover'; exit 1; }
echo 'ok busy startup recovers once writer releases lock'
