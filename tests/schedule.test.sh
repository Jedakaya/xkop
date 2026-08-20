#!/bin/sh
# Расписание подписок.
#
# Интервал принадлежит подписке, а задача cron просто просыпается достаточно
# часто, чтобы это заметить. Отдельно проверяется, что пустой кэш и никогда
# не обновлявшаяся подписка спрашиваются немедленно: расписание не должно
# мешать роутеру догнать то, чего у него нет.

set -u

ROOT=${ROOT:-$(dirname "$0")/..}
LIB="$ROOT/xkop/files/usr/lib/xkop"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

XKOP_LIB_DIR="$LIB"
# shellcheck source=/dev/null
. "$LIB/constants.sh"
XKOP_LIB_DIR="$LIB"
XKOP_CACHE_DIR="$work/cache"
XKOP_RUN_DIR="$work/run"
XKOP_CONFIG=xkop
# shellcheck source=/dev/null
. "$LIB/logging.sh"
# shellcheck source=/dev/null
. "$LIB/subscription.sh"

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

check "часы" "3600" "$(subscription_interval_seconds 1h)"
check "минуты" "1800" "$(subscription_interval_seconds 30m)"
check "сутки" "86400" "$(subscription_interval_seconds 1d)"
check "секунды" "45" "$(subscription_interval_seconds 45s)"
check "число без единицы — часы" "7200" "$(subscription_interval_seconds 2)"
# Ноль означал бы «спрашивать панель на каждом цикле», поэтому непонятное
# значение падает в час, а не в ноль.
check "непонятное значение — час" "3600" "$(subscription_interval_seconds 'скоро')"
check "пустое значение — час" "3600" "$(subscription_interval_seconds '')"

# uci подменяется: расписание проверяется само по себе, без роутера.
uci() {
    case "$3" in
        *) ;;
    esac
    case "$*" in
        *update_interval*) echo "1h" ;;
        *) return 1 ;;
    esac
}

mkdir -p "$XKOP_CACHE_DIR/main"

now=$(date +%s)

# Никогда не обновлялась — спрашиваем сразу.
printf '{"subscription":"main","state":"absent","updated_at":null,"servers":0}' \
    > "$XKOP_CACHE_DIR/main/meta.json"
echo '[]' > "$XKOP_CACHE_DIR/main/pool.json"
check "никогда не обновлялась — пора" "yes" "$(subscription_due main && echo yes || echo no)"

# Обновлялась только что, но серверов нет: расписание не должно держать
# роутер без узлов до следующего часа.
printf '{"subscription":"main","state":"empty","updated_at":%s,"servers":0}' "$now" \
    > "$XKOP_CACHE_DIR/main/meta.json"
check "пустой пул — пора, несмотря на расписание" "yes" "$(subscription_due main && echo yes || echo no)"

# Обновлялась только что и серверы есть — ждём.
printf '{"subscription":"main","state":"ready","updated_at":%s,"servers":5}' "$now" \
    > "$XKOP_CACHE_DIR/main/meta.json"
printf '[{"tag":"a"},{"tag":"b"}]' > "$XKOP_CACHE_DIR/main/pool.json"
check "свежая подписка не спрашивается заново" "no" "$(subscription_due main && echo yes || echo no)"

# Прошёл интервал — пора.
printf '{"subscription":"main","state":"ready","updated_at":%s,"servers":5}' "$((now - 4000))" \
    > "$XKOP_CACHE_DIR/main/meta.json"
check "по истечении интервала — пора" "yes" "$(subscription_due main && echo yes || echo no)"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
