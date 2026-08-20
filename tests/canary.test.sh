#!/bin/sh
# Канарейка: обнаружение подмены DNS.
#
# Ответы резолвера подставляются заглушкой, потому что проверять надо разбор
# и решение, а не сеть под тестом. Формы вывода взяты busybox-овские: именно
# они будут на роутере.

set -u

ROOT=${ROOT:-$(dirname "$0")/..}
LIB="$ROOT/xkop/files/usr/lib/xkop"

failed=0
total=0

check() {
    local label="$1" expected="$2" actual="$3"
    total=$((total + 1))
    if [ "$expected" = "$actual" ]; then
        echo "ok   $label"
    else
        echo "FAIL $label: ожидалось '$expected', получено '$actual'"
        failed=$((failed + 1))
    fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# Заглушка uci: хранит значения в файле, понимает get, show, add_list, delete
# и commit — этого хватает и Канарейке, и чтению списков.
cat > "$work/bin/uci" << 'STUB'
#!/bin/sh
CONF="$XKOP_TEST_UCI"
args=""
for a in "$@"; do [ "$a" = "-q" ] && continue; args="$args $a"; done
set -- $args
case "$1" in
    get)   line=$(grep -F "$2=" "$CONF" | head -1); [ -n "$line" ] || exit 1; printf '%s\n' "${line#*=}" ;;
    show)  grep "^$2\." "$CONF" || exit 1 ;;
    add_list) printf '%s\n' "$2" >> "$CONF" ;;
    delete) key="$2"; grep -v -F "$key=" "$CONF" > "$CONF.tmp"; mv "$CONF.tmp" "$CONF" ;;
    commit) : ;;
    *) exit 1 ;;
esac
STUB

# Заглушка nslookup в форме busybox: адрес сервера пишется с портом,
# ответы — без. На этом различии и держится разбор.
cat > "$work/bin/nslookup" << 'STUB'
#!/bin/sh
echo "Server:		127.0.0.1"
echo "Address:	127.0.0.1:53"
echo ""
if [ -n "$CANARY_FAKE_ANSWER" ]; then
    echo "Non-authoritative answer:"
    echo "Name:	$1"
    echo "Address: $CANARY_FAKE_ANSWER"
else
    echo "nslookup: can't resolve '$1'" >&2
    exit 1
fi
STUB

chmod +x "$work/bin/uci" "$work/bin/nslookup"
PATH="$work/bin:$PATH"
export PATH

XKOP_TEST_UCI="$work/uci.txt"
export XKOP_TEST_UCI
printf 'xkop.settings=settings\nxkop.settings.canary_enabled=1\n' > "$XKOP_TEST_UCI"

XKOP_LIB_DIR="$LIB"
# shellcheck source=/dev/null
. "$LIB/constants.sh"
XKOP_LIB_DIR="$LIB"
XKOP_CONFIG=xkop
XKOP_RUN_DIR="$work/run"
# shellcheck source=/dev/null
. "$LIB/logging.sh"
# shellcheck source=/dev/null
. "$LIB/subscription.sh"
# shellcheck source=/dev/null
. "$LIB/config.sh"
# shellcheck source=/dev/null
. "$LIB/canary.sh"

CANARY_FAKE_ANSWER=""
export CANARY_FAKE_ANSWER

check "имя для проверки не может существовать" "yes" \
    "$(case "$(canary_random_name)" in *.invalid) echo yes ;; *) echo no ;; esac)"
check "имя каждый раз новое" "yes" \
    "$([ "$(canary_random_name)" != "$(canary_random_name)" ] && echo yes || echo no)"

check "честный резолвер ничего не выдаёт" "" "$(canary_addresses somename)"
check "честная сеть — состояние clean" "clean" \
    "$(canary_run > /dev/null 2>&1; jq -r '.state' "$XKOP_RUN_DIR/canary.json")"
check "в честной сети выучивать нечего" "[]" \
    "$(jq -c '.learned' "$XKOP_RUN_DIR/canary.json")"

# Провайдер отвечает своим адресом на имя, которого не существует.
CANARY_FAKE_ANSWER="46.191.166.9"
check "подменённый ответ разобран" "46.191.166.9" "$(canary_addresses somename)"

canary_run > /dev/null 2>&1
check "подмена опознана" "hijacked" "$(jq -r '.state' "$XKOP_RUN_DIR/canary.json")"
check "адрес заглушки выучен" '["46.191.166.9"]' "$(jq -c '.detected' "$XKOP_RUN_DIR/canary.json")"
check "изменение отмечено" "true" "$(jq -r '.changed' "$XKOP_RUN_DIR/canary.json")"
check "выученное сохранено в настройки" "46.191.166.9" \
    "$(canary_learned | tr '\n' ' ' | sed 's/ *$//')"

canary_run > /dev/null 2>&1
check "повторная проверка не считается изменением" "false" \
    "$(jq -r '.changed' "$XKOP_RUN_DIR/canary.json")"

# Перехват сняли: выученное надо забыть, иначе честный ответ будет
# отбраковываться до конца жизни роутера.
CANARY_FAKE_ANSWER=""
canary_run > /dev/null 2>&1
check "после снятия перехвата состояние снова чистое" "clean" \
    "$(jq -r '.state' "$XKOP_RUN_DIR/canary.json")"
check "выученное забыто" "[]" "$(jq -c '.learned' "$XKOP_RUN_DIR/canary.json")"
check "забывание отмечено как изменение" "true" \
    "$(jq -r '.changed' "$XKOP_RUN_DIR/canary.json")"

# Выключенная Канарейка ничего не проверяет и ничего не утверждает.
printf 'xkop.settings=settings\nxkop.settings.canary_enabled=0\n' > "$XKOP_TEST_UCI"
canary_run > /dev/null 2>&1
check "выключенная не проверяет" "disabled" "$(jq -r '.state' "$XKOP_RUN_DIR/canary.json")"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
