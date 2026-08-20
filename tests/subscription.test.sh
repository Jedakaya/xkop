#!/bin/sh
# Extraction of a server pool from the Xray-native subscription formats,
# deduplication between subscriptions and tag assignment.
#
# The samples are constructed from the format description confirmed by working
# podkop code, not captured from a live panel: shapes are right, servers are
# fictional. Checking against a real subscription is still pending.

set -u

ROOT=${ROOT:-$(dirname "$0")/..}
JQ=${JQ:-jq}
PROGRAM="$ROOT/xkop/files/usr/lib/xkop/subscription.jq"
FIXTURES="$ROOT/tests/fixtures/subscription"

if ! command -v "$JQ" > /dev/null 2>&1 && [ ! -x "$JQ" ]; then
    echo "jq not found: $JQ" >&2
    exit 2
fi

failed=0
total=0

check() {
    local label="$1" expected="$2" actual="$3"
    total=$((total + 1))
    if [ "$expected" = "$actual" ]; then
        echo "ok   $label"
    else
        echo "FAIL $label"
        echo "     ожидалось: $expected"
        echo "     получено:  $actual"
        failed=$((failed + 1))
    fi
}

# Один разобранный ответ -> его серверы.
pool() {
    "$JQ" -c --arg mode pool --arg subscription "$1" --arg format "$2" \
        -f "$PROGRAM" "$3"
}

# Пулы нескольких подписок -> общий пул.
merge() {
    "$JQ" -c --arg mode merge --arg subscription "" --arg format "" -f "$PROGRAM"
}

happ=$(pool main xray-config-list "$FIXTURES/happ.json")
xrayjson=$(pool spare xray-json "$FIXTURES/xray-json.json")

check "серверов в Happ-ответе" "4" \
    "$(printf '%s' "$happ" | "$JQ" 'length')"
check "служебные исходящие не попали в пул" "true" \
    "$(printf '%s' "$happ" | "$JQ" -c 'all(.[]; .protocol != "freedom" and .protocol != "blackhole")')"
check "адрес и порт вынуты из vnext" '["nl2.example.com",443]' \
    "$(printf '%s' "$happ" | "$JQ" -c '.[0] | [.address, .port]')"
check "адрес и порт вынуты из плоских настроек" '["de1.example.com",8443]' \
    "$(printf '%s' "$happ" | "$JQ" -c '.[1] | [.address, .port]')"
check "исходящее скопировано как есть" '"sZ9m0Zp2Qk3xWv1nB7cA5dE8fG2hJ4kL6mN8pQ0rS2t"' \
    "$(printf '%s' "$happ" | "$JQ" -c '.[0].outbound.streamSettings.realitySettings.publicKey')"
# Hysteria2 в конфигурации Xray называется протоколом hysteria с версией 2:
# имя hysteria2 движок не знает и конфигурацию отвергнет.
check "hysteria2 распознан" '"hysteria"' \
    "$(printf '%s' "$happ" | "$JQ" -c '.[1].protocol')"
check "идентификатор взят из auth" '"s3cr3t-pass"' \
    "$(printf '%s' "$happ" | "$JQ" -c '.[1].identity')"

check "серверов в конфигурации движка" "2" \
    "$(printf '%s' "$xrayjson" | "$JQ" 'length')"
check "dns-исходящее не попало в пул" "true" \
    "$(printf '%s' "$xrayjson" | "$JQ" -c 'all(.[]; .protocol != "dns")')"

merged=$(printf '[%s,%s]' "$happ" "$xrayjson" | merge)

check "дубликат между подписками схлопнут" "5" \
    "$(printf '%s' "$merged" | "$JQ" 'length')"
check "победил более богатый формат" '"xray-config-list"' \
    "$(printf '%s' "$merged" | "$JQ" -c '.[] | select(.address == "nl2.example.com") | .format')"
check "реальность у победителя сохранилась" "true" \
    "$(printf '%s' "$merged" | "$JQ" -c '.[] | select(.address == "nl2.example.com") | .outbound.streamSettings.security == "reality"')"
check "теги уникальны" "true" \
    "$(printf '%s' "$merged" | "$JQ" -c '([.[].tag] | length) == ([.[].tag] | unique | length)')"
check "совпавшее имя получило номер" "true" \
    "$(printf '%s' "$merged" | "$JQ" -c '[.[].tag] | index("NL-Amsterdam-2 #2") != null')"
check "зарезервированное имя не занято узлом" "true" \
    "$(printf '%s' "$merged" | "$JQ" -c 'all(.[]; .tag != "direct" and .tag != "block" and .tag != "dns-out")')"
check "тег проставлен в само исходящее" "true" \
    "$(printf '%s' "$merged" | "$JQ" -c 'all(.[]; .outbound.tag == .tag)')"
check "источник запомнен" '["main","main","main","main","spare"]' \
    "$(printf '%s' "$merged" | "$JQ" -c '[.[].subscription]')"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
