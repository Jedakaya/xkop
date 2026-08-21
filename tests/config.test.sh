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
check "поддельные адреса только для маршрутизируемых имён" '["geosite:google","example.com","ads.example.com"]' "$(q fakeip.json '[.dns.servers[] | select(.address == "fakedns")] | first | .domains')"

# Исключения обязаны стоять РАНЬШЕ подделки: FakeDNS отвечает на всё, что
# до него дошло, и фильтр по доменам у него не работает — проверено на живом
# движке. Единственный способ оставить имя настоящим — перечислить его выше.
check "исключения стоят раньше подделки" 'true' "$(q fakeip.json '(.dns.servers | map(.address) | index("fakedns")) > 0')"
check "адрес пробы не подделывается" 'true' "$(q fakeip.json '[.dns.servers[] | select(.address != "fakedns") | .domains[]?] | any(startswith("domain:connectivitycheck"))')"
check "серверы узлов не подделываются" 'true' "$(q fakeip.json '[.dns.servers[] | select(.address != "fakedns") | .domains[]?] | any(startswith("domain:de1."))')"
check "резолвер-адрес в исключения не попадает" 'false' "$(q fakeip.json '[.dns.servers[] | .domains[]?] | any(. == "domain:8.8.8.8")')"
check "выученная заглушка ушла в отбраковку" '["46.191.166.9"]' "$(q fakeip.json '[.dns.servers[] | select(.unexpectedIPs != null)] | first | .unexpectedIPs')"
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
check "без настройки интерфейс не навязан" 'null' "$(q dns-case.json '.outbounds[] | select(.tag == "direct") | .streamSettings.sockopt.interface // null')"

# --- метка собственного трафика движка ------------------------------------
#
# Без неё получается петля: движок отправляет соединение наружу, правило
# в цепочке вывода видит поддельный адрес и заворачивает пакет обратно
# в движок. Тысячи соединений за секунды, триста пятьдесят мегабайт памяти,
# OOM и перезагрузка роутера — ровно это и наблюдалось на железе.

check "метка стоит на прямом исходящем" '4194304' "$(q dns-case.json '.outbounds[] | select(.tag == "direct") | .streamSettings.sockopt.mark')"
check "и на служебном dns" '4194304' "$(q dns-case.json '.outbounds[] | select(.tag == "dns-out") | .streamSettings.sockopt.mark')"
check "чёрной дыре она не нужна" 'null' "$(q dns-case.json '.outbounds[] | select(.tag == "block") | .streamSettings // null')"
check "метка есть у всех, кто ходит наружу" 'true' "$(q dns-case.json '[.outbounds[] | select(.protocol != "blackhole") | .streamSettings.sockopt.mark] | all(. == 4194304)')"



# --- журнал доступа и уровень подробности --------------------------------
#
# Проверено на живом движке: при loglevel "none" файл журнала доступа
# не создаётся вовсе, при "error" и "warning" — пишется. Выбор «молчать»
# тихо убивал разбор маршрута, и команда честно отвечала «записи о пробе нет»,
# не понимая причины.

dns_case '{"log_level": "none", "access_log": "1", "dns_extra": []}'
check "молчать и вести журнал одновременно нельзя" '"error"' "$(q dns-case.json '.log.loglevel')"
check "журнал доступа при этом на месте" 'true' "$(q dns-case.json '(.log.access != "none")')"

dns_case '{"log_level": "none", "access_log": "0", "dns_extra": []}'
check "без журнала доступа молчание уважается" '"none"' "$(q dns-case.json '.log.loglevel')"

dns_case '{"log_level": "warning", "access_log": "1", "dns_extra": []}'
check "обычный уровень не трогается" '"warning"' "$(q dns-case.json '.log.loglevel')"

# --- стратегия берётся из канала ------------------------------------------

dns_case '{"strategy": "leastPing", "dns_extra": []}'
check "выбранная стратегия доезжает до балансировщика" '"leastPing"' "$(q dns-case.json '.routing.balancers[0].strategy.type')"

dns_case '{"strategy": "leastLoad", "dns_extra": []}'
check "у leastLoad появляются пороги против скачков" '["300ms","600ms","1s"]' "$(q dns-case.json '.routing.balancers[0].strategy.settings.baselines')"

# --- буферы -------------------------------------------------------------
#
# Умолчание движка — 512 КБ на направление каждого соединения, оно рассчитано
# на настольную машину. На роутере это сотни мегабайт: движок вырос до 350 МБ
# при 496 МБ всего, ядро вызвало OOM-killer, админка перестала отвечать,
# роутер ушёл в перезагрузку, а задержки узлов выросли втрое — и это легко
# принять за качество подписки.

dns_case '{"dns_extra": []}'
check "буфер прижат" '4' "$(q dns-case.json '.policy.levels."0".bufferSize')"
check "простой соединения ограничен" '300' "$(q dns-case.json '.policy.levels."0".connIdle')"
check "после закрытия одной стороны ждём секунду" '1' "$(q dns-case.json '.policy.levels."0".uplinkOnly')"
check "счётчики трафика не потеряны" 'true' "$(q dns-case.json '.policy.system.statsOutboundUplink')"

dns_case '{"buffer_size_kb": 64, "dns_extra": []}'
check "буфер настраивается" '64' "$(q dns-case.json '.policy.levels."0".bufferSize')"

# --- источники целиком в туннель ------------------------------------------

dns_case '{"fully_routed_ip": ["192.168.1.10", "192.168.1.11"], "dns_extra": []}'
check "правило по источнику появилось" '["192.168.1.10","192.168.1.11"]' "$(q dns-case.json '[.routing.rules[] | select(.source? != null) | .source] | first')"
check "источник уходит в пул" '"pool"' "$(q dns-case.json '.routing.rules[] | select(.source? != null) | .balancerTag')"

# Локальные сети должны решаться раньше: устройству, которому велено ходить
# через туннель, всё равно нужен сосед по сети и сам роутер.
check "локальные сети решаются раньше" 'true' "$(q dns-case.json '(.routing.rules | map(has("ip")) | index(true)) < (.routing.rules | map(has("source")) | index(true))')"

dns_case '{"fully_routed_ip": [], "dns_extra": []}'
check "без настройки правила по источнику нет" 'null' "$(q dns-case.json '[.routing.rules[] | select(.source? != null)] | first // null')"

# --- локальный резолвер как апстрим ---------------------------------------
#
# Перехват апстрима AdGuard Home проверкой доступности не поймать: сам он жив
# и отвечает. Ловится он отбраковкой ответа, а значит выученное Канарейкой
# обязано стоять на КАЖДОМ сервере группы, а не только на первом.

dns_case '{"dns_server": "192.168.1.1", "dns_type": "udp", "dns_extra": ["https://8.8.8.8/dns-query"], "canary_learned": ["46.191.166.9"]}'
# Локальный резолвер встречается дважды: первым — как исключение для имён,
# которые нельзя подделывать, и следом как обычный сервер группы. Отбраковка
# нужна на том, который отвечает на всё; исключению она не мешает и не важна.
check "отбраковка стоит на локальном резолвере" 'true' "$(q dns-case.json '[.dns.servers[] | select(.address == "192.168.1.1" and (.domains | not))] | first | has("unexpectedIPs")')"
check "и на шифрованном рядом" 'true' "$(q dns-case.json '[.dns.servers[] | select(.address == "https://8.8.8.8/dns-query")] | first | has("unexpectedIPs")')"
check "списки отбраковки совпадают, группа цела" '1' "$(q dns-case.json '[.dns.servers[] | select(.unexpectedIPs != null) | .unexpectedIPs] | unique | length')"
check "и опрашиваются одновременно" 'true' "$(q dns-case.json '.dns.enableParallelQuery')"

# Каждый случай выше — это конфигурация, которую движок ещё не видел. Проверять
# только структуру тут мало: схема адреса и sockopt.interface либо принимаются
# движком, либо роняют запуск, и мнение теста в этом вопросе ничего не стоит.
if command -v "$XRAY" > /dev/null 2>&1; then
    dns_case_engine() {
        dns_case "$2"
        total=$((total + 1))
        if "$XRAY" run -test -format json -c "$work/dns-case.json" > "$work/dns-case.err" 2>&1; then
            echo "ok   движок принимает: $1"
        else
            echo "FAIL движок отверг: $1"
            head -n 3 "$work/dns-case.err" | sed 's/^/     /'
            failed=$((failed + 1))
        fi
    }

    dns_case_engine "DoH со схемой" '{"dns_server": "dns.adguard-dns.com", "dns_type": "doh", "dns_extra": []}'
    dns_case_engine "DoT" '{"dns_server": "1.1.1.1", "dns_type": "dot", "dns_extra": []}'
    dns_case_engine "QUIC" '{"dns_server": "1.1.1.1", "dns_type": "quic", "dns_extra": []}'
    dns_case_engine "TCP" '{"dns_server": "1.1.1.1", "dns_type": "tcp", "dns_extra": []}'
    dns_case_engine "опорный резолвер" '{"dns_server": "dns.adguard-dns.com", "dns_type": "doh", "dns_bootstrap": "77.88.8.8", "dns_extra": []}'
    dns_case_engine "интерфейс наружу" '{"output_interface": "wan", "dns_extra": []}'
    dns_case_engine "параллельный опрос" '{"dns_parallel": "1", "dns_extra": []}'
    dns_case_engine "источники целиком в туннель" '{"fully_routed_ip": ["192.168.1.10"], "dns_extra": []}'
    dns_case_engine "локальный резолвер рядом с шифрованным" '{"dns_server": "192.168.1.1", "dns_type": "udp", "dns_extra": ["https://8.8.8.8/dns-query"], "canary_learned": ["46.191.166.9"]}'
fi

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

# --- кэш ответов и подсказка о клиенте --------------------------------------
#
# Имя может жить на двух CDN сразу: ответы чередуются, а один из них
# у провайдера не работает. Закреплённый ответ тогда делает сайт мёртвым
# до конца TTL. Переписи TTL, как rewrite_ttl у sing-box, в Xray нет вовсе -
# в разборе конфигурации такого поля не существует, - поэтому единственный
# рычаг здесь disableCache.
#
# И движок молча выбрасывает незнакомые поля: проверять их наличие, скармливая
# ему конфигурацию, бесполезно - он примет и выдуманное. Имена сверены
# по infra/conf/dns.go.

# Настройки правятся поверх готового образца: генератору нужен полный набор
# полей, и обрезанный ввод он честно отвергает.
gen_dns() { "$JQ" -c "$1" "$FIXTURES/fakeip.json" | "$JQ" -f "$PROGRAM"; }

out=$(gen_dns '.')
check "по умолчанию кэш включён" "false" "$(printf '%s' "$out" | "$JQ" -c '.dns.disableCache')"
check "подсказки о клиенте нет" "true"     "$(printf '%s' "$out" | "$JQ" -c '.dns | has("clientIp") | not')"

out=$(gen_dns '.settings.dns_cache = "0" | .settings.dns_client_ip = "203.0.113.7"')
check "кэш выключается настройкой" "true" "$(printf '%s' "$out" | "$JQ" -c '.dns.disableCache')"
check "подсказка о клиенте передана" '"203.0.113.7"'     "$(printf '%s' "$out" | "$JQ" -c '.dns.clientIp')"

# --- локальный резолвер не остаётся один ------------------------------------
#
# AdGuard Home или Pi-hole поднимается не мгновенно и не обязательно раньше
# нас: порядок запуска служб OpenWrt при одинаковом START не определён. Пока
# он поднимается, спрашивать некого - имена не резолвятся, проверка узлов
# уходит в никуда, и снаружи это выглядит как «все серверы мёртвые». На живом
# роутере так и было: через тринадцать минут после старта ни одного замера
# при полностью исправном туннеле.

out=$(gen_dns '.settings.dns_server = "127.0.0.10" | .settings.dns_extra = []')
check "рядом с локальным встаёт шифрованный" "true"     "$(printf '%s' "$out" | "$JQ" -c '[.dns.servers[] | .address? // .] | any(startswith("https://"))')"

out=$(gen_dns '.settings.dns_server = "8.8.8.8" | .settings.dns_extra = []')
check "внешнему резолверу сосед не навязывается" "2"     "$(printf '%s' "$out" | "$JQ" -c '[.dns.servers[] | .address? // . | select(. != "fakedns")] | length')"

out=$(gen_dns '.settings.dns_server = "127.0.0.10" | .settings.dns_extra = ["https://1.1.1.1/dns-query"]')
check "заданный руками сосед не подменяется" "true"     "$(printf '%s' "$out" | "$JQ" -c '[.dns.servers[] | .address? // .] | any(. == "https://1.1.1.1/dns-query") and (any(. == "https://8.8.8.8/dns-query") | not)')"

# Схема адреса локальность не отменяет.
out=$(gen_dns '.settings.dns_server = "https://127.0.0.1/dns-query" | .settings.dns_extra = []')
check "локальный по схеме тоже опознан" "true"     "$(printf '%s' "$out" | "$JQ" -c '[.dns.servers[] | .address? // .] | any(. == "https://8.8.8.8/dns-query")')"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
