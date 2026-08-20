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

# Журнал доступа пишется в каталог, который на роутере создаёт сама служба.
# В проверке подставляется путь внутри временного каталога — движок при
# запуске требует, чтобы каталог существовал.
generate() {
    "$JQ" --arg path "$work/access.log" '.settings.access_log_path = $path' "$FIXTURES/$1.json"         | "$JQ" -f "$PROGRAM" > "$work/$1.json"
}

for fixture in with-pool empty-pool fakeip protection; do
    generate "$fixture"
done

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

# Режим fakeip: имена решаются DNS-слоем движка, а не именем внутри соединения.
check "по умолчанию DNS не трогается" "false"     "$(q with-pool.json 'has("dns")')"
check "по умолчанию поддельных адресов нет" "false"     "$(q with-pool.json 'has("fakedns")')"
check "по умолчанию слушателя DNS нет" '["tproxy-in","probe-in"]'     "$(q with-pool.json '[.inbounds[].tag]')"

check "в режиме fakeip появляется слушатель DNS" '["tproxy-in","probe-in","dns-in"]'     "$(q fakeip.json '[.inbounds[].tag]')"

# Журнал доступа — это то, на чём держится разбор маршрута: движок пишет
# в него выбранный исходящий по каждому соединению.
check "журнал доступа включён по умолчанию" "true"     "$(q with-pool.json '.log.access != "none"')"
check "слушатель для проб только на петле" '"127.0.0.1"'     "$(q with-pool.json '.inbounds[] | select(.tag == "probe-in") | .listen')"
check "распознавание разворачивает поддельный адрес" "true"     "$(q fakeip.json '.inbounds[0].sniffing.destOverride | index("fakedns") != null')"
check "поддельные адреса только для маршрутизируемых имён" '["geosite:google","example.com","ads.example.com"]'     "$(q fakeip.json '.dns.servers[0].domains')"
check "выученная заглушка ушла в отбраковку" '["46.191.166.9"]'     "$(q fakeip.json '.dns.servers[1].unexpectedIPs')"
check "параллельный опрос при нескольких серверах" "true"     "$(q fakeip.json '.dns.enableParallelQuery')"
check "запросы с DNS-слушателя уходят резолверу" '"dns-out"'     "$(q fakeip.json '.routing.rules[0].outboundTag')"
check "пул поддельных адресов задан" '"198.18.0.0/15"'     "$(q fakeip.json '.fakedns.ipPool')"

# Защита от обхода: клиент со своим резолвером мимо нас не ходит незаметно.
check "по умолчанию ничего не блокируется" "0"     "$(q with-pool.json '[.routing.rules[] | select(.port? or .protocol?)] | length')"
check "порт 853 закрыт целиком" '"block"'     "$(q protection.json '.routing.rules[] | select(.port? == 853) | .outboundTag')"
check "публичные DoH закрыты на 443" "19"     "$(q protection.json '.routing.rules[] | select(.port? == 443) | .ip | length')"
check "quic отключается отдельно" '"block"'     "$(q protection.json '.routing.rules[] | select(.protocol? != null) | .outboundTag')"
check "защита стоит раньше правил привязок" "true"     "$(q protection.json '([.routing.rules[] | select(.port? == 853)] | length) > 0 and (.routing.rules | map(has("port")) | index(true)) < (.routing.rules | map(has("balancerTag")) | index(true))')"

# --- настройки, которые раньше объявлялись и не читались ------------------
#
# dns_type, dns_bootstrap, dns_parallel и output_interface лежали в
# /etc/config/xkop и в интерфейсе, а генератор их не смотрел: что ни выбери,
# на роутер уезжало одно и то же. Проверки ниже держат каждую подключённой.

dns_case() {
    "$JQ" --arg path "$work/access.log" --argjson s "$1" '.settings.access_log_path = $path | .settings += $s' "$FIXTURES/fakeip.json" | "$JQ" -f "$PROGRAM" > "$work/dns-case.json"
}

dns_case '{"dns_server": "dns.adguard-dns.com", "dns_type": "doh", "dns_extra": []}'
check "DoH получает схему https" '"https://dns.adguard-dns.com/dns-query"' "$(q dns-case.json '[.dns.servers[] | .address] | map(select(startswith("https://"))) | first')"

dns_case '{"dns_server": "1.1.1.1", "dns_type": "dot", "dns_extra": []}'
check "DoT получает схему tls" '"tls://1.1.1.1"' "$(q dns-case.json '[.dns.servers[] | .address] | map(select(startswith("tls://"))) | first')"

dns_case '{"dns_server": "8.8.8.8", "dns_type": "udp", "dns_extra": []}'
check "обычный UDP остаётся адресом" '"8.8.8.8"' "$(q dns-case.json '[.dns.servers[] | .address] | map(select(. == "8.8.8.8")) | first')"

dns_case '{"dns_server": "https+local://1.1.1.1/dns-query", "dns_type": "udp", "dns_extra": []}'
check "вписанная схема побеждает выбор способа" '"https+local://1.1.1.1/dns-query"' "$(q dns-case.json '[.dns.servers[] | .address] | map(select(startswith("https+local://"))) | first')"

dns_case '{"dns_server": "dns.adguard-dns.com", "dns_type": "doh", "dns_bootstrap": "77.88.8.8", "dns_extra": []}'
check "опорный резолвер добавлен для имени" '"77.88.8.8"' "$(q dns-case.json '[.dns.servers[] | .address] | last')"

dns_case '{"dns_server": "8.8.8.8", "dns_type": "udp", "dns_bootstrap": "77.88.8.8", "dns_extra": []}'
check "для адреса опорный не нужен" 'false' "$(q dns-case.json '[.dns.servers[] | .address] | any(. == "77.88.8.8")')"

dns_case '{"dns_parallel": "1", "dns_extra": []}'
check "параллельный опрос включается настройкой" 'true' "$(q dns-case.json '.dns.enableParallelQuery')"

dns_case '{"output_interface": "wan2", "dns_extra": []}'
check "интерфейс наружу проставлен прямому исходящему" '"wan2"' "$(q dns-case.json '.outbounds[] | select(.tag == "direct") | .streamSettings.sockopt.interface')"

dns_case '{"dns_extra": []}'
check "без настройки интерфейс не навязан" 'null' "$(q dns-case.json '.outbounds[] | select(.tag == "direct") | .streamSettings // null')"

if command -v "$XRAY" > /dev/null 2>&1; then
    for f in with-pool empty-pool fakeip protection; do
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
