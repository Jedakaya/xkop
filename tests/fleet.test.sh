#!/bin/sh
# Optional management must remain independent from VPN runtime.
set -eu
ROOT=${ROOT:-$(dirname "$0")/..}
CLIENT="$ROOT/xkop/files/usr/bin/xkop-fleet"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
export XKOP_FLEET_DIR="$TMP/state"
export XKOP_FLEET_LOCK="$TMP/lock"
export FLEET_TEST_CALLS="$TMP/calls"
mkdir "$TMP/bin"
cat > "$TMP/bin/curl" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$FLEET_TEST_CALLS"
if [ -n "${FLEET_TEST_READY:-}" ]; then
    : > "$FLEET_TEST_READY"
    sleep 3
fi
output= data=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) output=$2; shift;;
        --data-binary) data=${2#@}; shift;;
    esac
    shift
done
case "${FLEET_TEST_RESPONSE:-ok}" in
    deny) printf '{"error":"unauthorized"}' > "$output"; printf 401;;
    broken) printf '{}' > "$output"; printf 200;;
    *) jq '{registered: true, accepted: true, device_id: .device_id}' "$data" > "$output"; printf 200;;
esac
MOCK
chmod +x "$TMP/bin/curl"
cat > "$TMP/bin/od" <<'NO_OD'
#!/bin/sh
echo 'od must not be required by the OpenWrt client' >&2
exit 99
NO_OD
chmod +x "$TMP/bin/od"
export PATH="$TMP/bin:$PATH"

sh "$CLIENT" heartbeat
sh "$CLIENT" run
[ ! -e "$FLEET_TEST_CALLS" ]
[ ! -e "$XKOP_FLEET_DIR" ]
echo 'ok: public install creates no identity and sends no requests'

printf '%064d\n' 1 > "$TMP/invite"
for url in http://example.test https:// https:///foo 'https://user:pass@example.test' 'https://example.test/#key' 'https://example.test/"'; do
    if sh "$CLIENT" enroll "$url" "$TMP/invite" >/dev/null 2>&1; then
        echo 'FAIL: invalid URL accepted'; exit 1
    fi
done
[ ! -e "$FLEET_TEST_CALLS" ]
echo 'ok: HTTPS and safe URL required'

export FLEET_TEST_RESPONSE=broken
if sh "$CLIENT" enroll https://fleet.example.test "$TMP/invite" >/dev/null 2>&1; then exit 1; fi
[ ! -e "$XKOP_FLEET_DIR/enabled" ]
cp "$XKOP_FLEET_DIR/identity.json" "$TMP/first.json"
export FLEET_TEST_RESPONSE=ok
sh "$CLIENT" enroll https://fleet.example.test "$TMP/invite"
cmp "$XKOP_FLEET_DIR/identity.json" "$TMP/first.json"
[ -f "$XKOP_FLEET_DIR/enabled" ]
if sh "$CLIENT" enroll https://another.example.test "$TMP/invite" >/dev/null 2>&1; then exit 1; fi
sh "$CLIENT" heartbeat
mkdir "$XKOP_FLEET_LOCK"
: > "$XKOP_FLEET_LOCK/2147483647"
sh "$CLIENT" heartbeat
[ ! -d "$XKOP_FLEET_LOCK" ]
mkdir "$XKOP_FLEET_LOCK"
: > "$XKOP_FLEET_LOCK/$$"
if sh "$CLIENT" heartbeat >/dev/null 2>&1; then echo 'FAIL: live owner ignored'; exit 1; fi
rm "$XKOP_FLEET_LOCK/$$"
rmdir "$XKOP_FLEET_LOCK"
echo 'ok: dead operation recovered; live operation respected'

# Force the recovery mkdir-to-PID window: B claims the replacement directory
# while A is paused just after recreating the old stale lock.
export FLEET_REAL_MKDIR
FLEET_REAL_MKDIR=$(command -v mkdir)
export FLEET_REAL_SLEEP
FLEET_REAL_SLEEP=$(command -v sleep)
export FLEET_RACE_DIR="$TMP/race"
mkdir "$FLEET_RACE_DIR"
cat > "$TMP/bin/mkdir" <<'MKDIR'
#!/bin/sh
"$FLEET_REAL_MKDIR" "$@" || exit $?
if [ "${FLEET_RACE_ROLE:-}" = A ] && [ "$1" = "$XKOP_FLEET_LOCK" ]; then
    : > "$FLEET_RACE_DIR/a-ready"
    tries=0
    while [ ! -f "$FLEET_RACE_DIR/release-a" ] && [ "$tries" -lt 10 ]; do
        "$FLEET_REAL_SLEEP" 1; tries=$((tries + 1))
    done
fi
MKDIR
cat > "$TMP/bin/sleep" <<'SLEEP'
#!/bin/sh
if [ "${FLEET_RACE_ROLE:-}" = B ] && [ "$1" = 1 ]; then
    tries=0
    while [ ! -f "$FLEET_RACE_DIR/a-ready" ] && [ "$tries" -lt 10 ]; do
        "$FLEET_REAL_SLEEP" 1; tries=$((tries + 1))
    done
else
    "$FLEET_REAL_SLEEP" "$@"
fi
SLEEP
chmod +x "$TMP/bin/mkdir" "$TMP/bin/sleep"
mkdir "$XKOP_FLEET_LOCK"
: > "$XKOP_FLEET_LOCK/2147483647"
race_before=$(wc -l < "$FLEET_TEST_CALLS")
FLEET_RACE_ROLE=A sh "$CLIENT" heartbeat >/dev/null 2>&1 &
race_a=$!
FLEET_RACE_ROLE=B FLEET_TEST_READY="$FLEET_RACE_DIR/b-ready" sh "$CLIENT" heartbeat >/dev/null 2>&1 &
race_b=$!
tries=0
while [ ! -f "$FLEET_RACE_DIR/b-ready" ] && [ "$tries" -lt 10 ]; do
    "$FLEET_REAL_SLEEP" 1; tries=$((tries + 1))
done
[ -f "$FLEET_RACE_DIR/b-ready" ]
: > "$FLEET_RACE_DIR/release-a"
if wait "$race_a"; then
    wait "$race_b" || :
    echo 'FAIL: two recovery contenders both acquired ownership'; exit 1
fi
wait "$race_b"
[ "$(wc -l < "$FLEET_TEST_CALLS")" -eq "$((race_before + 1))" ] || {
    echo 'FAIL: both recovery contenders reached the network'; exit 1
}
rm "$TMP/bin/mkdir" "$TMP/bin/sleep"
echo 'ok: concurrent recovery has only one owner'

secret=$(jq -r .secret "$TMP/first.json")
if grep -F "$secret" "$FLEET_TEST_CALLS"; then echo 'FAIL: secret leaked to arguments'; exit 1; fi
if grep -F "$(cat "$TMP/invite")" "$FLEET_TEST_CALLS"; then echo 'FAIL: invitation leaked'; exit 1; fi
echo 'ok: enrollment retry preserves identity; secrets absent from arguments'

FLEET_TEST_READY="$TMP/ready" sh "$CLIENT" enroll https://fleet.example.test "$TMP/invite" >/dev/null &
enrolling=$!
attempt=0
while [ ! -f "$TMP/ready" ] && [ "$attempt" -lt 10 ]; do sleep 1; attempt=$((attempt + 1)); done
[ -f "$TMP/ready" ]
if sh "$CLIENT" disable >/dev/null 2>&1; then
    wait "$enrolling"
    echo 'FAIL: disable claimed success while enrollment could re-enable it'; exit 1
fi
wait "$enrolling"
sh "$CLIENT" disable
[ ! -e "$XKOP_FLEET_DIR/enabled" ]
before=$(wc -l < "$FLEET_TEST_CALLS")
sh "$CLIENT" heartbeat
sh "$CLIENT" run
[ "$(wc -l < "$FLEET_TEST_CALLS")" -eq "$before" ]
sh "$CLIENT" enroll https://fleet.example.test "$TMP/invite" >/dev/null
echo 'ok: disable is serialized with enrollment and stops future requests'

export FLEET_TEST_RESPONSE=deny
if sh "$CLIENT" heartbeat; then echo 'FAIL: denial accepted'; exit 1; fi
[ ! -e "$XKOP_FLEET_DIR/enabled" ]
before=$(wc -l < "$FLEET_TEST_CALLS")
sh "$CLIENT" run
sh "$CLIENT" heartbeat
[ "$(wc -l < "$FLEET_TEST_CALLS")" -eq "$before" ]
echo 'ok: revoked agent stops polling without touching VPN'
