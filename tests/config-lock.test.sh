#!/bin/sh
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_RUN_DIR="$work" XKOP_STATE_DIR="$work" XKOP_CONFIG_PATH="$work/config.json"
XKOP_LIB_DIR="$ROOT/xkop/files/usr/lib/xkop"
. "$XKOP_LIB_DIR/lock.sh"
. "$XKOP_LIB_DIR/config.sh"
log_info() { :; }; log_warn() { :; }; log_error() { :; }
config_input_json() { cat "$ROOT/tests/fixtures/config/with-pool.json"; }
config_validate() { return 0; }
echo '{}' > "$XKOP_CONFIG_PATH"
lock_acquire config
if config_generate; then
 echo 'FAIL generator ignored an active config writer'
 exit 1
fi
lock_release config
config_generate || exit 1
[ -f "$work/config-reload.pending" ] || { echo 'FAIL installed config has no pending reload marker'; exit 1; }
echo 'ok   config writers serialize and preserve pending reload'
