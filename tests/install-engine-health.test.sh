#!/bin/sh
# An exit-zero diagnostic JSON must not discard the only working engine copy.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
lab=$(mktemp -d)
trap 'rm -rf "$lab"' EXIT
failed=0
check() { if [ "$2" = "$3" ]; then echo "ok $1"; else echo "FAIL $1: expected $2 got $3"; failed=$((failed+1)); fi; }
{
    sed -n '/^engine_room_restore()/,/^}/p' "$ROOT/install.sh"
    sed -n '/^engine_install_verified()/,/^}/p' "$ROOT/install.sh"
} | sed "s|/usr/bin/xray|$lab/xray|g; s|/usr/bin/xkop|$lab/check-engine|g" > "$lab/functions"
awk '/^if \/usr\/bin\/xkop check_engine/ || /^if engine_install_verified/ {copy=1} copy {print} copy && /^fi$/ {exit}' \
    "$ROOT/install.sh" | sed "s|/usr/bin/xkop|$lab/check-engine|g" > "$lab/final-check"
. "$lab/functions"
note() { :; }; warn() { :; }
WAS_RUNNING=0
printf '#!/bin/sh\ncat "%s/result.json"\n' "$lab" > "$lab/check-engine"
printf '#!/bin/sh\necho "Xray 26.10.31 (Xray)"\n' > "$lab/xray"
chmod +x "$lab/check-engine" "$lab/xray"
for result in '{"engine_installed":false,"engine_version_ok":false}' 'not-json' '{"engine_installed":true,"engine_version_ok":false}'; do
    printf '%s\n' "$result" > "$lab/result.json"
    printf good > "$lab/stash"; ENGINE_STASH="$lab/stash"
    . "$lab/final-check" >/dev/null
    check "stopped service retains backup on $result" yes "$([ -s "$lab/stash" ] && echo yes || echo no)"
done
printf '%s\n' '{"engine_installed":true,"engine_version_ok":true,"engine_version":"26.10.31"}' > "$lab/result.json"
printf '#!/bin/sh\nexit 1\n' > "$lab/xray"
printf good > "$lab/stash"; ENGINE_STASH="$lab/stash"
. "$lab/final-check" >/dev/null
check 'cached healthy JSON cannot hide broken binary' yes "$([ -s "$lab/stash" ] && echo yes || echo no)"
printf '#!/bin/sh\necho "Xray 26.10.31 (Xray)"\n' > "$lab/xray"
printf good > "$lab/stash"; ENGINE_STASH="$lab/stash"
. "$lab/final-check" >/dev/null
check 'verified stopped-service engine releases backup' no "$([ -s "$lab/stash" ] && echo yes || echo no)"
WAS_RUNNING=1; started=0
printf good > "$lab/stash"; ENGINE_STASH="$lab/stash"
. "$lab/final-check" >/dev/null
check 'failed previously running service retains backup' yes "$([ -s "$lab/stash" ] && echo yes || echo no)"
[ "$failed" = 0 ]
