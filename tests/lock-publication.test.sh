#!/bin/sh
# Pause the first claimant at publication, then let another claimant win.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export XKOP_RUN_DIR="$work"
export XKOP_TEST_LOCK_LIB="$ROOT/xkop/files/usr/lib/xkop/lock.sh"
# shellcheck source=/dev/null
. "$XKOP_TEST_LOCK_LIB"
log_warn() { :; }
cat > "$work/claimant" <<'CLAIMANT'
#!/bin/sh
. "$XKOP_TEST_LOCK_LIB"
log_warn() { :; }
publication_pause() {
 : > "$XKOP_RUN_DIR/paused"
 while [ ! -f "$XKOP_RUN_DIR/resume" ]; do sleep 1; done
}
# The first hook reproduces the old empty-mkdir window. The second pauses
# the corrected implementation before its atomic prepared-owner publication.
mkdir() {
 command mkdir "$@"; result=$?
 if [ "$result" = 0 ] && [ "$*" = "$XKOP_RUN_DIR/lock-work" ]; then publication_pause; fi
 return "$result"
}
mv() {
 case "${2:-}" in "$XKOP_RUN_DIR"/lock-new.*) publication_pause;; esac
 command mv "$@"
}
if lock_acquire work; then echo 0; else echo 1; fi > "$XKOP_RUN_DIR/first-result"
CLAIMANT
sh "$work/claimant" &
first=$!
i=0
while [ ! -f "$work/paused" ] && [ "$i" -lt 5 ]; do sleep 1; i=$((i+1)); done
[ -f "$work/paused" ] || { echo 'FAIL claimant did not reach publication'; kill "$first"; exit 1; }
lock_acquire work || { echo 'FAIL independent claimant could not acquire'; : > "$work/resume"; wait "$first"; exit 1; }
owner=$(cat "$work/lock-work/identity")
: > "$work/resume"
wait "$first"
[ "$(cat "$work/first-result")" = 1 ] || { echo 'FAIL suspended claimant also acquired the live lock'; exit 1; }
[ "$(cat "$work/lock-work/identity")" = "$owner" ] || { echo 'FAIL suspended claimant overwrote live ownership'; exit 1; }
lock_release work
echo 'ok delayed fresh claimant cannot overwrite a live owner'
