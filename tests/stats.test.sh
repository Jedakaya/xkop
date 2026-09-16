#!/bin/sh
# Runs the stats normalizer against recorded metrics samples and compares the
# result with the frozen contract in tests/expected.
#
# The samples reproduce what the Xray endpoint actually serves, including the
# omitempty gaps of OutboundStatus and both observatory implementations with
# their different units. See docs/stats.md.

set -u

ROOT=${ROOT:-$(dirname "$0")/..}
JQ=${JQ:-jq}
PROGRAM="$ROOT/xkop/files/usr/lib/xkop/stats.jq"

ADDRESS='127.0.0.1:11111'
COLLECTED_AT=1755600000

if ! command -v "$JQ" > /dev/null 2>&1 && [ ! -x "$JQ" ]; then
    echo "jq not found: $JQ" >&2
    exit 2
fi

failed=0
total=0

for fixture in "$ROOT"/tests/fixtures/metrics/*.json; do
    name=$(basename "$fixture" .json)
    expected="$ROOT/tests/expected/metrics/$name.json"
    total=$((total + 1))

    if [ ! -f "$expected" ]; then
        echo "FAIL $name: нет ожидаемого вывода"
        failed=$((failed + 1))
        continue
    fi

    # jq под Windows выводит CRLF; ожидаемый вывод хранится с LF, как и всё,
    # что уезжает на роутер. Сравнение не должно зависеть от того, где запущено.
    actual=$("$JQ" --arg address "$ADDRESS" --argjson collected_at "$COLLECTED_AT" \
        -f "$PROGRAM" "$fixture" 2>&1 | tr -d '\r')

    if [ "$actual" = "$(cat "$expected")" ]; then
        echo "ok   $name"
    else
        echo "FAIL $name"
        printf '%s\n' "$actual" | diff -u "$expected" - | head -40
        failed=$((failed + 1))
    fi
done

# --- распределение считает клиентов, а не пробы ---------------------------

dist() {
    printf '%s' "$1" | "$JQ" -c --arg address "$ADDRESS" --argjson collected_at "$COLLECTED_AT" \
        --argjson bypass "$2" -f "$PROGRAM" 2>&1 | tr -d '\r'
}

check() {
    total=$((total + 1))
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1: ожидалось '$2', получено '$3'"
        failed=$((failed + 1))
    fi
}

# Роутер без клиентов: на узлах только пробы наблюдателя. Туннель показывал
# сто процентов.
idle='{"stats":{"inbound":{"tproxy-in":{"uplink":0,"downlink":0},"probe-in":{"uplink":0,"downlink":0}},
 "outbound":{"direct":{"uplink":0,"downlink":0},"block":{"uplink":0,"downlink":0},
 "resolver-out":{"uplink":3000,"downlink":5000},
 "node-a":{"uplink":8000,"downlink":10000}}}}'
out=$(dist "$idle" '{"up":0,"down":0}')
check "пробы узлов — не туннель" "0" "$(printf '%s' "$out" | "$JQ" '.distribution.proxy.bytes')"
check "без клиентов и всего ноль" "0" "$(printf '%s' "$out" | "$JQ" '.traffic.clients_total')"
check "запросы резолвера движка — служебное, не напрямую" "0 8000" "$(printf '%s' "$out" | "$JQ" -r '"\(.distribution.direct.bytes) \(.distribution.service.bytes)"')"

# Выборочный перехват: в движок вошло 1000 байт, из них 200 ушли напрямую
# из движка; 5000 байт прошли мимо движка вовсе. Узел отправил больше
# вошедшего — пробы сверху.
busy='{"stats":{"inbound":{"tproxy-in":{"uplink":400,"downlink":600}},
 "outbound":{"direct":{"uplink":100,"downlink":100},"block":{"uplink":0,"downlink":0},
 "node-a":{"uplink":2000,"downlink":3000}}}}'
out=$(dist "$busy" '{"up":1000,"down":4000}')
check "туннель — вошедшее минус прямое" "800" "$(printf '%s' "$out" | "$JQ" '.distribution.proxy.bytes')"
check "напрямую — из движка и мимо него" "5200" "$(printf '%s' "$out" | "$JQ" '.distribution.direct.bytes')"
check "доля туннеля от клиентского" "0.1333" "$(printf '%s' "$out" | "$JQ" '.distribution.proxy.share')"

# Счётчиков nft нет — мимо движка ничего не прибавляется, но пробы всё равно
# не туннель.
out=$(dist "$busy" 'null')
check "без счётчиков nft напрямую только из движка" "200" "$(printf '%s' "$out" | "$JQ" '.distribution.direct.bytes')"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
