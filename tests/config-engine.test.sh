#!/bin/sh
# Exercise the actual temporary files passed to the shipped engine.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
XRAY=${XRAY:-xray}
if ! command -v "$XRAY" >/dev/null 2>&1; then
    echo 'skip actual candidate validation: Xray unavailable'
    exit 0
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_RUN_DIR="$work/run"
XKOP_STATE_DIR="$work/state"
XKOP_CONFIG_PATH="$work/config.json"
XKOP_LIB_DIR="$ROOT/xkop/files/usr/lib/xkop"
XKOP_ENGINE_BIN="$XRAY"
mkdir -p "$XKOP_RUN_DIR" "$XKOP_STATE_DIR"
. "$XKOP_LIB_DIR/config.sh"
. "$XKOP_LIB_DIR/nodes.sh"
log_info() { :; }; log_warn() { :; }; log_error() { :; }
config_input_json() {
    jq --arg pin "${1-}" '. + {manual_pin: $pin}' "$ROOT/tests/fixtures/config/with-pool.json"
}
nodes_api() { return 0; }
failed=0
if config_generate; then
    echo 'ok   generated candidate is accepted by the real engine'
else
    echo 'FAIL real engine rejects generated candidate'
    failed=$((failed + 1))
    config_input_json | jq -f "$XKOP_LIB_DIR/config.jq" > "$XKOP_CONFIG_PATH"
fi
rm -f "$XKOP_RUN_DIR/config-reload.pending"
if nodes_apply_selection DE-Frankfurt-1; then
    echo 'ok   selection candidate is accepted by the real engine'
else
    echo 'FAIL real engine rejects selection candidate'
    failed=$((failed + 1))
fi
[ "$failed" -eq 0 ]
