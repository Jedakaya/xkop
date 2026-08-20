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

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
