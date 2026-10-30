#!/bin/sh
# Startup restoration must serialize with interactive node selection.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_STATE_DIR="$work"
. "$ROOT/xkop/files/usr/lib/xkop/service.sh"
XKOP_RECOVERY_ATTEMPTS="$work/attempts"
engine_wait() { return 0; }
subscription_retry_failed() { :; }
nodes_keep() { echo unsafe > "$work/result"; }
lock_run() { echo locked > "$work/result"; }
service_started_check
i=0
while [ ! -f "$work/result" ] && [ "$i" -lt 5 ]; do sleep 1; i=$((i + 1)); done
if [ "$(cat "$work/result" 2>/dev/null)" != locked ]; then
    echo 'FAIL startup restoration bypassed selection lock'
    exit 1
fi
echo 'ok   startup restoration shares selection lock'
