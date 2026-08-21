#!/bin/sh
# Проверка на живом роутере. Запускается НА РОУТЕРЕ:
#
#   sh /tmp/smoke.sh
#
# Зачем она есть отдельно от tests/. Оффлайновые проверки подменяют заглушками
# всё, что трогает роутер: чтение uci, nft, dnsmasq, движок. Значит целый класс
# отказов они не видят по устройству — и однажды не увидели: строгий режим убил
# штатные функции OpenWrt, чтение списков стало возвращать пустоту, роутер
# собрал конфигурацию без единого правила и погнал весь трафик напрямую.
# Служба при этом работала, движок отвечал, правила «были».
#
# Отсюда правило этой проверки: смотреть не на наличие, а на СОДЕРЖИМОЕ.
# «Таблица есть» ничего не значит, если в ней ноль адресов. «Команда
# отработала» ничего не значит, если она вернула пустоту.

failed=0
total=0

ok() { total=$((total + 1)); echo "ok   $1"; }
bad() {
    total=$((total + 1))
    failed=$((failed + 1))
    echo "ПЛОХО $1"
    [ -n "${2:-}" ] && echo "      $2"
}

need() {
    # need "что проверяем" "значение" "чем должно быть не меньше"
    if [ -z "$2" ] || [ "$2" = "null" ]; then
        bad "$1" "пусто"
    elif [ "$2" -lt "$3" ] 2> /dev/null; then
        bad "$1" "получено $2, ожидалось не меньше $3"
    else
        ok "$1 ($2)"
    fi
}

echo "== чтение настроек"

# Ровно то, что сломалось молча: списки uci читаются штатными функциями
# OpenWrt, и они не переносят строгий режим.
profiles=$(uci -q show xkop 2> /dev/null | sed -n 's/^xkop\.\([^.=]*\)=profile$/\1/p')
[ -n "$profiles" ] && ok "профили найдены ($(echo "$profiles" | tr '\n' ' '))" \
    || bad "профили найдены" "ни одного"

lists=0
for id in $profiles; do
    for opt in community_list domain subnet; do
        # Строгий режим здесь обязателен: именно в нём штатные функции
        # OpenWrt умирают и возвращают пустоту. Проверка без него проходит
        # на сломанном роутере — я на это уже наступил.
        n=$(sh -c "set -u
            . /usr/lib/xkop/constants.sh
            . /usr/lib/xkop/logging.sh
            . /usr/lib/xkop/subscription.sh
            subscription_config_list '$id' '$opt'" 2> /dev/null | grep -c .)
        lists=$((lists + n))
    done
done
need "списки профилей читаются" "$lists" 1

echo
echo "== конфигурация движка"

cfg=/etc/xkop/config.json
[ -s "$cfg" ] && ok "конфигурация на месте" || bad "конфигурация на месте" "файла нет"

need "правил маршрутизации" "$(jq '[.routing.rules[]] | length' "$cfg" 2> /dev/null)" 2
need "адресов в правилах" "$(jq '[.routing.rules[] | select(.ip != null) | .ip[]] | length' "$cfg" 2> /dev/null)" 1
need "исходящих" "$(jq '[.outbounds[]] | length' "$cfg" 2> /dev/null)" 3

if [ "$(uci -q get xkop.settings.dns_mode)" = "fakeip" ]; then
    need "серверов DNS" "$(jq '[.dns.servers[]] | length' "$cfg" 2> /dev/null)" 2
    fake=$(jq -r '[.dns.servers[] | .address? // .] | index("fakedns")' "$cfg" 2> /dev/null)
    [ "$fake" != "null" ] && ok "подделка адресов включена" \
        || bad "подделка адресов включена" "fakedns в списке серверов нет"
fi

echo
echo "== правила на роутере"

if nft list table inet xkop > /dev/null 2>&1; then
    ok "таблица nft на месте"
    elements=$(nft list set inet xkop routed4 2> /dev/null | tr ',' '\n' | grep -c '[0-9][.][0-9]')
    need "адресов в наборе перехвата" "$elements" 1
else
    bad "таблица nft на месте" "таблицы нет — трафик идёт напрямую"
fi

echo
echo "== служба и движок"

engine=$(xkop check_engine 2> /dev/null)
[ "$(printf '%s' "$engine" | jq -r '.engine_installed')" = "true" ] \
    && ok "движок установлен" || bad "движок установлен"
[ "$(printf '%s' "$engine" | jq -r '.engine_answering')" = "true" ] \
    && ok "движок отвечает" || bad "движок отвечает" "процесс может быть, а эндпоинт молчать"

need "узлов в пуле" "$(xkop nodes 2> /dev/null | jq '[.nodes[]] | length')" 1

echo
echo "== все команды отдают JSON"

for c in get_status check_engine stats nodes subscriptions global_check \
    check_dns_available check_fakeip check_nft_rules get_system_info version; do
    out=$(xkop "$c" 2>&1)
    if printf '%s' "$out" | jq -e . > /dev/null 2>&1; then
        ok "$c"
    else
        bad "$c" "$(printf '%s' "$out" | head -c 120)"
    fi
done

echo
echo "== расписание"

# Задача, вписанная в расписание под именем, которого нет в CLI, не выполняется
# никогда и молча. Проверяется не наличие строк, а то, что каждая названная
# команда существует и отрабатывает.
cron_lines=$(grep -c 'xkop' /etc/crontabs/root 2> /dev/null)
need "задач в расписании" "${cron_lines:-0}" 5

for c in $(awk '{for (i = 1; i < NF; i++) if ($i ~ /bin.xkop$/) print $(i + 1)}'     /etc/crontabs/root 2> /dev/null | sort -u); do
    out=$(xkop "$c" 2>&1 | head -c 100)
    case "$out" in
        *"not found"* | *"unbound variable"* | *"parameter not set"*)
            bad "команда из расписания: $c" "$out" ;;
        *) ok "команда из расписания: $c" ;;
    esac
done

echo
echo "== имена продолжают резолвиться после остановки"

# Резолвер клиентов переключён на движок. Если при остановке он не вернётся
# обратно, вся сеть остаётся без имён — при том что сам роутер жив и на вид
# исправен.
/etc/init.d/xkop stop > /dev/null 2>&1
sleep 3
if nslookup ya.ru 127.0.0.1 > /dev/null 2>&1; then
    ok "после остановки имена резолвятся"
else
    bad "после остановки имена резолвятся" "dnsmasq остался смотреть на выключенный движок"
fi
/etc/init.d/xkop start > /dev/null 2>&1
sleep 18

echo
echo "== тонкости OpenWrt"

# Без K-ссылки stop_service при выключении роутера не вызывается никогда,
# и резолвер остаётся направленным на движок, которого после перезагрузки нет.
if ls /etc/rc.d/ 2> /dev/null | grep -q '^K[0-9]*xkop$'; then
    ok "останов при выключении роутера включён"
else
    bad "останов при выключении роутера включён" "нет ссылки K в /etc/rc.d"
fi

# Всё состояние лежит вне /etc/config и без этого файла теряется при sysupgrade.
if [ -s /lib/upgrade/keep.d/xkop ]; then
    ok "состояние переживёт обновление прошивки"
else
    bad "состояние переживёт обновление прошивки" "нет /lib/upgrade/keep.d/xkop"
fi

# Пять секунд по умолчанию мало движку с сотнями соединений.
tt=$(ubus call service list 2> /dev/null | jq -r '.xkop.instances.engine.term_timeout // 0' 2> /dev/null)
need "времени на мягкое завершение движка" "${tt:-0}" 10

# Имена, у которых подмена адреса ломает работу молча: push iOS, Xiaomi.
excluded=$(jq '[.inbounds[0].sniffing.domainsExcluded[]?] | length' /etc/xkop/config.json 2> /dev/null)
need "исключений распознавания" "${excluded:-0}" 3

echo
echo "== замок не отменяет запуск службы"

# Тот самый случай: обновление пакета останавливает службу, а запуск попадает
# на идущую задачу по расписанию. Правила обязаны вернуться.
mkdir -p /tmp/xkop/lock-work
sleep 120 &
held=$!
echo "$held" > /tmp/xkop/lock-work/pid

/etc/init.d/xkop stop > /dev/null 2>&1
/etc/init.d/xkop start > /dev/null 2>&1
sleep 20

if nft list table inet xkop > /dev/null 2>&1; then
    elements=$(nft list set inet xkop routed4 2> /dev/null | tr ',' '\n' | grep -c '[0-9][.][0-9]')
    need "правила вернулись при занятом замке" "$elements" 1
else
    bad "правила вернулись при занятом замке" "таблицы нет"
fi

kill "$held" 2> /dev/null
rm -rf /tmp/xkop/lock-work

echo
echo "$((total - failed))/$total"
[ "$failed" -eq 0 ]
