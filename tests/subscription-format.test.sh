#!/bin/sh
# Format detection of a subscription payload: what arrived and how much of it
# is usable. See docs/subscription.md - the state machine may not replace a
# working cache until this answers.

set -u

ROOT=${ROOT:-$(dirname "$0")/..}
FIXTURES="$ROOT/tests/fixtures/subscription"

XKOP_LIB_DIR="$ROOT/xkop/files/usr/lib/xkop"
export XKOP_LIB_DIR

# shellcheck source=/dev/null
. "$XKOP_LIB_DIR/subscription.sh"

failed=0
total=0

check() {
    local label="$1" expected="$2" actual="$3"
    total=$((total + 1))
    if [ "$expected" = "$actual" ]; then
        echo "ok   $label"
    else
        echo "FAIL $label: ожидалось $expected, получено $actual"
        failed=$((failed + 1))
    fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

check "формат Happ" "xray-config-list" "$(subscription_detect_format "$FIXTURES/happ.json")"
check "конфигурация движка" "xray-json" "$(subscription_detect_format "$FIXTURES/xray-json.json")"
check "список ссылок" "link-list" "$(subscription_detect_format "$FIXTURES/link-list.txt")"
check "список ссылок в url-safe без добивки" "link-list" \
    "$(subscription_detect_format "$FIXTURES/link-list-urlsafe.txt")"
check "мусор" "unknown" "$(subscription_detect_format "$FIXTURES/junk.txt")"

: > "$work/empty"
check "пустой файл" "unknown" "$(subscription_detect_format "$work/empty")"

# Провайдер может отдать gzip независимо от заголовков запроса. Без распаковки
# ответ выглядит бинарным мусором, и причина отказа называется неверная.
gzip -c "$FIXTURES/happ.json" > "$work/happ.gz"
check "сжатый ответ до распаковки" "unknown" "$(subscription_detect_format "$work/happ.gz")"
subscription_decompress_gzip "$work/happ.gz"
check "сжатый ответ после распаковки" "xray-config-list" "$(subscription_detect_format "$work/happ.gz")"

cp "$FIXTURES/happ.json" "$work/plain.json"
subscription_decompress_gzip "$work/plain.json"
check "несжатый файл не тронут" "0" "$(cmp -s "$FIXTURES/happ.json" "$work/plain.json"; echo $?)"

check "серверов в Happ-ответе" "4" \
    "$(subscription_count_servers "$FIXTURES/happ.json" xray-config-list)"
check "серверов в конфигурации движка" "2" \
    "$(subscription_count_servers "$FIXTURES/xray-json.json" xray-json)"
check "ссылок в списке" "4" \
    "$(subscription_count_servers "$FIXTURES/link-list.txt" link-list)"
check "ссылок в url-safe списке" "5" \
    "$(subscription_count_servers "$FIXTURES/link-list-urlsafe.txt" link-list)"

# Отдельно про хвост. GNU base64 останавливается на первом символе не своего
# алфавита и печатает то, что успел, с нулевым кодом возврата: список молча
# обрезается на первом "-" или "_", и серверы после него исчезают. Проверка
# именно на последнюю ссылку, потому что теряется всегда хвост.
check "url-safe: хвост списка не потерян" "1" \
    "$(subscription_decode_link_list "$FIXTURES/link-list-urlsafe.txt" | grep -c 'ru0.example.com')"
check "в мусоре серверов нет" "0" \
    "$(subscription_count_servers "$FIXTURES/junk.txt" unknown)"

# Считаются пригодные ссылки, а не все подряд: в этом списке 14 строк, из них
# движок соберёт 8. Обещать 14 значило бы показать населённой подписку,
# половина которой не заработает.
check "смешанный список опознан" "link-list" \
    "$(subscription_detect_format "$FIXTURES/link-list-mixed.txt")"
check "в смешанном списке считаются только пригодные" "8" \
    "$(subscription_count_servers "$FIXTURES/link-list-mixed.txt" link-list)"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
