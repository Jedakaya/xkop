#!/bin/sh
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export XKOP_RUN_DIR="$work"
export XKOP_TEST_LIB="$ROOT/xkop/files/usr/lib/xkop"
# Use the real dispatcher; only the router-facing selection operation is fake.
cat > "$work/cli" <<'SETUP'
#!/bin/sh
. "$XKOP_TEST_LIB/lock.sh"
log_info() { :; }; log_warn() { :; }
nodes_select() {
 : > "$XKOP_RUN_DIR/select-ready"
 while [ ! -f "$XKOP_RUN_DIR/go" ]; do sleep 1; done
 : > "$XKOP_RUN_DIR/selection-mutated"
}
SETUP
awk '/^main\(\) \{/ {copy=1} copy {print}' "$ROOT/xkop/files/usr/bin/xkop" >> "$work/cli"
sh "$work/cli" select synthetic &
worker=$!
i=0
while [ ! -f "$work/select-ready" ] && [ "$i" -lt 5 ]; do sleep 1; i=$((i+1)); done
kill -TERM "$(cat "$work/lock-work/pid")"
sleep 2
: > "$work/go"
wait "$worker" 2>/dev/null
[ ! -f "$work/selection-mutated" ] || { echo 'FAIL select continued after TERM released its lock'; exit 1; }
echo 'ok CLI selection terminates on signal before further mutation'
