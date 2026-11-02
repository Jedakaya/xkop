#!/bin/sh
# The lock must outlive a short-lived starter when its worker still runs.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_RUN_DIR="$work"
export XKOP_RUN_DIR
cat > "$work/start.sh" <<'START'
#!/bin/sh
. "$1/xkop/files/usr/lib/xkop/lock.sh"
log_info() { :; }; log_warn() { :; }
(
 lock_acquire work || exit 1
 : > "$XKOP_RUN_DIR/held"
 sleep 6
 lock_release work
) >/dev/null 2>&1 &
START
sh "$work/start.sh" "$ROOT"
i=0
while [ ! -f "$work/held" ] && [ "$i" -lt 4 ]; do sleep 1; i=$((i+1)); done
. "$ROOT/xkop/files/usr/lib/xkop/lock.sh"
log_info() { :; }; log_warn() { :; }
if lock_acquire work; then
 echo 'FAIL live subshell lock was treated as abandoned'
 exit 1
fi
echo 'ok   subshell lock retains the real worker PID'
