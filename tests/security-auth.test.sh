#!/bin/sh
# Exercise real CGI with isolated paths and a boundary fixture for rpcd.
set -eu
ROOT=${ROOT:-$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)}
JQ=${JQ:-jq}
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT INT TERM
export FIXTURE="$t"
mkdir "$t/bin"
printf '12345678-1234-1234-1234-123456789012\n' > "$t/uuid"
sed "s|/etc/shadow|$t/shadow|g;s|/proc/sys/kernel/random/uuid|$t/uuid|g" "$ROOT/client-panel/cgi-bin/auth" > "$t/auth"
sed "s|/tmp/xkop-panel-token|$t/token|g;s|/tmp/xkop-panel-failures|$t/failures|g" "$ROOT/client-panel/cgi-bin/_common" > "$t/_common"
cat > "$t/bin/ubus" <<'EOF'
#!/bin/sh
[ "$1 $2" = 'call session' ] || exit 1
case "$3" in
  login)
    printf '%s' "$4" > "$FIXTURE/request"
    [ ! -f "$FIXTURE/ubus-down" ] || exit 1
    [ ! -f "$FIXTURE/bad-reply" ] || { echo '{}'; exit; }
    printf '%s' "$4" | jq -e '.username == "root" and .password == "test+$\\\"&?pass"' >/dev/null || exit 1
    echo '{"ubus_rpc_session":"0123456789abcdef0123456789abcdef"}' ;;
  destroy) echo '{}' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$t/bin/ubus"
export PATH="$t/bin:$PATH"
failed=0
check() {
    label=$1 expected=$2 transport=${3:-on}
    rm -f "$t/token" "$t/failures" "$t/request"
    body='password=test%2B%24%5C%22%26%3Fpass'
    reply=$(printf '%s' "$body" | HTTPS="$transport" CONTENT_LENGTH=${#body} sh "$t/auth" | tail -n 1)
    if printf '%s' "$reply" | "$JQ" -e ".ok == $expected" >/dev/null; then
        echo "ok $label"
    else
        echo "FAIL $label (response redacted)"
        failed=$((failed + 1))
    fi
    if [ "$expected" = false ] && [ -f "$t/token" ]; then echo "FAIL rejected request created token"; failed=$((failed + 1)); fi
}
for hash in '*' '!' '!$6$locked' ''; do
    printf 'root:%s:0:0:99999:7:::\n' "$hash" > "$t/shadow"
    check "deny shadow [$hash]" false
done
rm "$t/shadow"; check 'deny missing shadow' false
printf 'guest:$6$fixture:0:0:99999:7:::\n' > "$t/shadow"; check 'deny absent root' false
printf 'root:$6$rounds=10000$fixture$hash:0:0:99999:7:::\n' > "$t/shadow"
check 'valid rpcd credential with special characters' true
check 'deny HTTP before password verification' false off
[ ! -f "$t/request" ] || { echo 'FAIL HTTP reached verifier'; failed=$((failed + 1)); }
touch "$t/ubus-down"; check 'deny unavailable rpcd' false; rm "$t/ubus-down"
touch "$t/bad-reply"; check 'deny malformed rpcd response' false
HTTPS=on
export HTTPS
. "$t/_common"
[ "$(urldecode 'literal\n\c+%2B%25%5C')" = 'literal\n\c +%\' ] || { echo 'FAIL literal backslash decoding'; failed=$((failed + 1)); }
urldecode 'line%0A' > "$t/decoded"
printf 'line\n' > "$t/expected"
cmp -s "$t/decoded" "$t/expected" || { echo 'FAIL newline decoding'; failed=$((failed + 1)); }
echo 'ok portable decoding preserves literal backslashes and newlines'
[ "$failed" -eq 0 ]
