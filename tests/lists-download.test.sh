#!/bin/sh
# A blocked direct connection must quickly fall back to the working tunnel.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
. "$ROOT/xkop/files/usr/lib/xkop/lists.sh"
XKOP_PROBE_PORT=10809
log_info() { :; }; xray() { :; }; engine_answers() { return 0; }
curl() {
    printf '%s\n' "$*" >> "$work/calls"
    case "$*" in
        *--socks5-hostname*)
            while [ "$1" != -o ]; do shift; done
            shift; printf downloaded > "$1"; return 0 ;;
        *) return 28 ;;
    esac
}
lists_download https://github.com/example/geosite.dat "$work/geosite" 120 || exit 1
head -n 1 "$work/calls" | grep -q -- '--connect-timeout 5 --max-time 15' || {
    echo 'FAIL a blocked direct connection delays fallback for the full asset timeout'; exit 1;
}
tail -n 1 "$work/calls" | grep -q -- '--max-time 120 --socks5-hostname 127.0.0.1:10809' || exit 1
[ "$(cat "$work/geosite")" = downloaded ] || exit 1
echo 'ok   blocked direct download falls back promptly with the full tunnel budget'
engine_answers() { return 1; }
: > "$work/calls"
if lists_download https://github.com/example/geosite.dat "$work/absent" 10; then exit 1; fi
[ "$(wc -l < "$work/calls" | tr -d ' ')" = 1 ] || exit 1
grep -q -- '--connect-timeout 5 --max-time 10' "$work/calls" || exit 1
echo 'ok   no tunnel request is attempted when the engine is down'
: > "$work/calls"
if lists_download https://github.com/example/geosite.dat "$work/absent" 120; then exit 1; fi
grep -q -- '--connect-timeout 5 --max-time 120' "$work/calls" || {
    echo 'FAIL direct budget is shortened without a usable tunnel fallback'; exit 1;
}
echo 'ok   a slow direct path keeps its full budget when no tunnel is available'
