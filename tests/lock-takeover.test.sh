#!/bin/sh
# The reaper must publish the next owner before allowing another contender in.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_RUN_DIR="$work"
. "$ROOT/xkop/files/usr/lib/xkop/lock.sh"
log_warn() { :; }
lock_reaping_release() {
 # Observe the transition at the real release boundary, then release normally.
 if [ "$(cat "$1/identity" 2>/dev/null)" != "$2" ]; then
  : > "$work/unowned-gap"
 fi
 rmdir "$1/reaping/${2%:*}-${2#*:}" 2>/dev/null
 rmdir "$1/reaping" 2>/dev/null
}
mkdir -p "$work/lock-work/reaping/999999-0"
echo 999999 > "$work/lock-work/pid"
lock_acquire work || { echo 'FAIL dead reaper could not be recovered'; exit 1; }
[ ! -f "$work/unowned-gap" ] || { echo 'FAIL reaper released before publishing its successor'; exit 1; }
lock_release work
[ ! -d "$work/lock-work" ] || { echo 'FAIL takeover left an unreleasable directory'; exit 1; }
echo 'ok stale takeover publishes ownership while reaping remains exclusive'
