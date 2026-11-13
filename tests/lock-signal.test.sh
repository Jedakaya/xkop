#!/bin/sh
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export XKOP_RUN_DIR="$work"
cat > "$work/worker" <<'WORKER'
#!/bin/sh
. "$1/xkop/files/usr/lib/xkop/lock.sh"
log_info() { :; }; log_warn() { :; }
job() {
 : > "$XKOP_RUN_DIR/ready"
 while [ ! -f "$XKOP_RUN_DIR/go" ]; do sleep 1; done
 : > "$XKOP_RUN_DIR/continued"
}
lock_run work job
WORKER
sh "$work/worker" "$ROOT" &
worker=$!
i=0
while [ ! -f "$work/ready" ] && [ "$i" -lt 5 ]; do sleep 1; i=$((i+1)); done
owner=$(cat "$work/lock-work/pid")
kill -TERM "$owner"
sleep 2
: > "$work/go"
wait "$worker" 2>/dev/null
[ ! -f "$work/continued" ] || { echo 'FAIL terminated worker continued'; exit 1; }
. "$ROOT/xkop/files/usr/lib/xkop/lock.sh"
log_warn() { :; }; log_info() { :; }
lock_acquire work || exit 1
sh -c '. "$1/xkop/files/usr/lib/xkop/lock.sh"; lock_release work' sh "$ROOT"
[ -d "$work/lock-work" ] || { echo 'FAIL foreign release removed lock'; exit 1; }
lock_release work
mkdir -p "$work/lock-work/reaping"
echo 999999 > "$work/lock-work/pid"
lock_acquire work || { echo 'FAIL interrupted stale reaper blocked recovery'; exit 1; }
lock_release work
mkdir -p "$work/lock-work"
read -r live_pid _ < /proc/self/stat
printf '%s' "$live_pid" > "$work/lock-work/pid"
printf '%s:0' "$live_pid" > "$work/lock-work/identity"
lock_acquire work || { echo 'FAIL recycled PID kept abandoned lock'; exit 1; }
lock_release work
# All contenders see one abandoned owner. Only one may enter the critical job.
mkdir -p "$work/lock-work"
echo 999999 > "$work/lock-work/pid"
pids=''
for contender in 1 2 3 4; do
 (
  if lock_acquire work; then
   echo acquired >> "$work/winners"
   sleep 3
   lock_release work
  fi
 ) &
 pids="$pids $!"
done
for pid in $pids; do wait "$pid"; done
[ "$(wc -l < "$work/winners" | tr -d ' ')" = 1 ] || { echo 'FAIL multiple stale contenders acquired lock'; exit 1; }
echo 'ok TERM stops worker and foreign release preserves owner'
