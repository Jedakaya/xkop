#!/bin/sh
# Генерация конфигурации движка.
#
# Проверяется структура, а если в системе есть сам Xray — ещё и то, что он эту
# конфигурацию принимает. Второе важнее первого: отвергнутая конфигурация
# означает роутер без движка, и мнение теста тут ничего не стоит.
#
#   XRAY=/путь/к/xray sh tests/config.test.sh

set -u

ROOT=${ROOT:-$(dirname "$0")/..}
JQ=${JQ:-jq}
XRAY=${XRAY:-xray}
PROGRAM="$ROOT/xkop/files/usr/lib/xkop/config.jq"
FIXTURES="$ROOT/tests/fixtures/config"

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

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

"$JQ" -f "$PROGRAM" "$FIXTURES/with-pool.json" > "$work/with-pool.json"
"$JQ" -f "$PROGRAM" "$FIXTURES/empty-pool.json" > "$work/empty-pool.json"

q() { "$JQ" -c "$2" "$work/$1"; }

check "служебные исходящие на месте" '["direct","block"]' \
    "$(q with-pool.json '[.outbounds[] | select(.protocol == "freedom" or .protocol == "blackhole") | .tag]')"
check "узлы скопированы в исходящие" '["NL-Amsterdam-2","DE-Frankfurt-1"]' \
    "$(q with-pool.json '[.outbounds[] | select(.protocol == "vless" or .protocol == "hysteria") | .tag]')"
check "исходящее узла не переписано" '"reality"' \
    "$(q with-pool.json '.outbounds[] | select(.tag == "NL-Amsterdam-2") | .streamSettings.security')"

check "балансировщик собирает весь пул" '["NL-Amsterdam-2","DE-Frankfurt-1"]' \
    "$(q with-pool.json '.routing.balancers[0].selector')"
check "запасной канал у балансировщика прямой" '"direct"' \
    "$(q with-pool.json '.routing.balancers[0].fallbackTag')"

# Балансировщик в движке требует наблюдения: без него конфигурация
# отвергается целиком с «not all dependencies are resolved».
check "наблюдение идёт вместе с балансировщиком" "true" \
    "$(q with-pool.json '(.burstObservatory.subjectSelector | length) == (.routing.balancers[0].selector | length)')"
check "интервал проверки строкой, а не числом" '"3m"' \
    "$(q with-pool.json '.burstObservatory.pingConfig.interval')"

check "первое правило оставляет локальное дома" '"direct"' \
    "$(q with-pool.json '.routing.rules[0].outboundTag')"
check "geoip.dat не требуется" "true" \
    "$(q with-pool.json '[.routing.rules[].ip? // [] | .[]] | all(startswith("geoip:") | not)')"
check "профиль ушёл в балансировщик" '"pool"' \
    "$(q with-pool.json '.routing.rules[] | select(.domain? and (.domain | index("example.com"))) | .balancerTag')"
check "подсети профиля стали отдельным правилом" '["203.0.113.0/24"]' \
    "$(q with-pool.json '.routing.rules[] | select(.balancerTag? and .ip?) | .ip')"
check "блокирующий канал блокирует" '"block"' \
    "$(q with-pool.json '.routing.rules[] | select(.domain? and (.domain | index("ads.example.com"))) | .outboundTag')"
check "порядок привязок соблюдён" '["example.com","ads.example.com","bank.example.com"]' \
    "$(q with-pool.json '[.routing.rules[] | select(.domain?) | .domain[-1]]')"

check "метрики слушают заданный порт" '"127.0.0.1:11111"' \
    "$(q with-pool.json '.metrics.listen')"
check "счётчики включены" "true" \
    "$(q with-pool.json '.policy.system.statsOutboundUplink')"

# Пустой пул — не отказ: подписка могла не приехать, а роутер обязан подняться.
check "без узлов балансировщика нет" "0" \
    "$(q empty-pool.json '.routing.balancers | length')"
check "без узлов наблюдения нет" "false" \
    "$(q empty-pool.json 'has("burstObservatory")')"
check "без узлов привязка уходит напрямую" '"direct"' \
    "$(q empty-pool.json '.routing.rules[] | select(.domain?) | .outboundTag')"

if command -v "$XRAY" > /dev/null 2>&1; then
    for f in with-pool empty-pool; do
        total=$((total + 1))
        if "$XRAY" run -test -format json -c "$work/$f.json" > "$work/$f.err" 2>&1; then
            echo "ok   движок принимает конфигурацию: $f"
        else
            echo "FAIL движок отверг конфигурацию: $f"
            tail -n 2 "$work/$f.err" | sed 's/^/     /'
            failed=$((failed + 1))
        fi
    done
else
    echo "--   движок не найден ($XRAY), проверка приёмки пропущена"
fi

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
