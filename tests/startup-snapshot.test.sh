#!/bin/sh
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_RUN_DIR="$work" XKOP_STATE_DIR="$work" XKOP_CONFIG_PATH="$work/config.json"
. "$ROOT/xkop/files/usr/lib/xkop/service.sh"
. "$ROOT/xkop/files/usr/lib/xkop/lock.sh"
log_info() { :; }; log_warn() { :; }
ubus() { printf '{"xkop":{"instances":{"engine":{"pid":%s}}}}' "$PID"; }
echo '{"version":1}' > "$XKOP_CONFIG_PATH"
cp "$XKOP_CONFIG_PATH" "$work/starting-config.json"
echo 11 > "$work/starting-engine.pid"
: > "$work/config-reload.pending"
PID=11
if service_finish_start; then echo 'FAIL old process confirmed a new config'; exit 1; fi
[ -f "$work/config-reload.pending" ] || exit 1
PID=22
service_finish_start || exit 1
[ ! -f "$work/config-reload.pending" ] || { echo 'FAIL new process did not confirm its snapshot'; exit 1; }
echo 'ok   new process confirms the startup snapshot'
: > "$work/config-reload.pending"
echo '{"version":2}' > "$XKOP_CONFIG_PATH"
service_finish_start || exit 1
[ -f "$work/config-reload.pending" ] || { echo 'FAIL newer config lost its pending reload'; exit 1; }
echo 'ok   newer configuration stays pending'

rm -f "$work/config-reload.pending"
cp "$work/starting-config.json" "$XKOP_CONFIG_PATH"
: > "$work/wan-reprobe.pending"
echo 1 > "$work/starting-wan.ready"
PID=11
if service_finish_start; then echo 'FAIL old engine confirmed its own post-WAN reprobe'; exit 1; fi
[ -f "$work/wan-reprobe.pending" ] || exit 1
PID=22

: > "$work/wan-reprobe.pending"
echo 0 > "$work/starting-wan.ready"
service_finish_start || exit 1
[ -f "$work/wan-reprobe.pending" ] || { echo 'FAIL pre-WAN startup cleared its reprobe'; exit 1; }
cp "$work/starting-config.json" "$XKOP_CONFIG_PATH"
echo 1 > "$work/starting-wan.ready"
service_finish_start || exit 1
[ ! -f "$work/wan-reprobe.pending" ] || { echo 'FAIL post-WAN startup did not confirm reprobe'; exit 1; }
echo 'ok   late WAN remains pending until a post-WAN start'

cp "$work/starting-config.json" "$XKOP_CONFIG_PATH"
cmp() {
 local result
 command cmp "$@"; result=$?
 : > "$work/compared"
 sleep 1
 return "$result"
}
(
 i=0
 while [ ! -f "$work/compared" ] && [ "$i" -lt 5 ]; do sleep 1; i=$((i+1)); done
 if lock_acquire config; then
  echo '{"version":3}' > "$XKOP_CONFIG_PATH"
  : > "$work/config-reload.pending"
  : > "$work/writer-applied"
  lock_release config
 else
  : > "$work/writer-blocked"
 fi
) &
writer=$!
service_finish_start
wait "$writer"
[ -f "$work/writer-blocked" ] || { echo 'FAIL startup confirmation raced with configuration writer'; exit 1; }
echo 'ok   startup confirmation serializes with config writers'
