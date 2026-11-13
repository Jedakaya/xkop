#!/bin/sh
# Every simultaneous stale-lock attempt must elect exactly one live owner.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_RUN_DIR="$work"
. "$ROOT/xkop/files/usr/lib/xkop/lock.sh"
log_warn() { :; }
pause=0.02 checks=250
if ! sleep "$pause" 2>/dev/null; then pause=1 checks=5; fi
round=0
while [ "$round" -lt "${XKOP_TEST_LOCK_ROUNDS:-20}" ]; do
 round=$((round+1))
 run="$work/round-$round"
 mkdir "$run" "$work/lock-work"
 echo 999999 > "$work/lock-work/pid"
 pids=''
 for contender in 1 2 3 4 5 6 7 8; do
  (
   result=1
   if lock_acquire work; then
    result=0
    : > "$run/winner-$contender"
   fi
   : > "$run/done-$contender"
   if [ "$result" = 0 ]; then
    # Hold the winning owner until every competing attempt has finished.
    while [ ! -f "$run/release" ]; do sleep "$pause"; done
    lock_release work
   fi
  ) &
  pids="$pids $!"
 done
 attempts=0
 while [ "$(find "$run" -name 'done-*' | wc -l | tr -d ' ')" != 8 ] && [ "$attempts" -lt "$checks" ]; do
  sleep "$pause"
  attempts=$((attempts+1))
 done
 winners=$(find "$run" -name 'winner-*' | wc -l | tr -d ' ')
 completed=$(find "$run" -name 'done-*' | wc -l | tr -d ' ')
 : > "$run/release"
 for pid in $pids; do wait "$pid"; done
 [ "$completed" = 8 ] || { echo "FAIL stale-lock election round $round did not finish: $completed/8 attempts"; exit 1; }
 if [ "$winners" != 1 ]; then
  echo "FAIL stale-lock election round $round: expected 1 owner, got $winners"
  find "$work/lock-work" -print 2>/dev/null
  exit 1
 fi
 [ ! -d "$work/lock-work" ] || { echo "FAIL winning owner could not release lock in round $round"; exit 1; }
done
echo "ok exactly one owner across $round stale-lock elections"
