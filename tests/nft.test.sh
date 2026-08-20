#!/bin/sh
# Правила nftables: что попадает в движок, а что остаётся дома.
#
# Проверяется текст набора правил, а не его применение: применить его можно
# только на роутере, и это делается на железе. Здесь ловится то, что дешевле
# поймать до выезда — пропавший интерфейс, забытая метка, исключение, которое
# не попало в набор.

set -u

ROOT=${ROOT:-$(dirname "$0")/..}
LIB="$ROOT/xkop/files/usr/lib/xkop"

# shellcheck source=/dev/null
. "$LIB/constants.sh"
# shellcheck source=/dev/null
. "$LIB/logging.sh"
# shellcheck source=/dev/null
. "$LIB/nft.sh"

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

has() {
    if printf '%s' "$1" | grep -qF "$2"; then echo yes; else echo no; fi
}

simple=$(nft_ruleset "br-lan" "")
fake=$(nft_ruleset "br-lan" "" 1)
two=$(nft_ruleset "br-lan br-guest" "192.168.1.3 192.168.1.4")

check "таблица названа по проекту" "yes" "$(has "$simple" "table inet xkop {")"
check "интерфейс источника попал в набор" "yes" "$(has "$simple" '"br-lan"')"
check "второй интерфейс тоже" "yes" "$(has "$two" '"br-guest"')"
check "чужие интерфейсы отбрасываются" "yes" "$(has "$simple" 'iifname != @interfaces return')"

check "локальные сети остаются дома" "yes" "$(has "$simple" 'ip daddr @local4 return')"
check "локальный IPv6 тоже" "yes" "$(has "$simple" 'ip6 daddr @local6 return')"

check "без исключений набора исключений нет" "no" "$(has "$simple" 'set excluded4')"
check "с исключениями набор появляется" "yes" "$(has "$two" 'set excluded4')"
check "исключённый источник отбрасывается" "yes" "$(has "$two" 'ip saddr @excluded4 return')"
check "исключённый адрес внутри набора" "yes" "$(has "$two" '192.168.1.3')"

check "метка ставится нашей" "yes" "$(has "$simple" "meta mark set $XKOP_NFT_MARK")"
check "tcp уходит в движок" "yes" \
    "$(has "$simple" "tproxy ip to $XKOP_TPROXY_ADDRESS:$XKOP_TPROXY_PORT")"
check "разметка и разворот разведены по цепочкам" "yes" \
    "$(has "$simple" 'chain proxy')"

# Приоритеты: разметка должна случиться раньше разворота, иначе метку некому
# будет увидеть.
mark_priority=$(printf '%s' "$simple" | sed -n 's/.*hook prerouting priority \(-[0-9]*\).*/\1/p' | head -n 1)
divert_priority=$(printf '%s' "$simple" | sed -n 's/.*hook prerouting priority \(-[0-9]*\).*/\1/p' | tail -n 1)
check "разметка раньше разворота" "yes" \
    "$([ "$mark_priority" -lt "$divert_priority" ] && echo yes || echo no)"

# Свой трафик роутера к поддельному адресу правила клиентов не видят: он не
# маршрутизируется, он здесь рождается.
check "без fakeip своей цепочки нет" "no" "$(has "$simple" 'chain mangle_output')"
check "в режиме fakeip цепочка появляется" "yes" "$(has "$fake" 'chain mangle_output')"
check "поддельный диапазон метится" "yes" "$(has "$fake" "ip daddr $XKOP_FAKEIP_RANGE")"
check "уже помеченное не метится повторно" "yes"     "$(has "$fake" "meta mark & $XKOP_NFT_MARK == $XKOP_NFT_MARK return")"

# Синхронизация времени мимо движка. Настройка exclude_ntp существовала
# в конфигурации и не делала ничего: правило под неё никто не выпускал.
ntp=$(nft_ruleset "br-lan" "" 0 1)
check "без настройки NTP не выделен" "no" "$(has "$simple" 'udp dport 123 return')"
check "с настройкой NTP уходит мимо" "yes" "$(has "$ntp" 'udp dport 123 return')"

# Выпуск NTP обязан стоять раньше разметки, иначе метка уже проставлена и
# возвращать поздно.
ntp_line=$(printf '%s' "$ntp" | grep -n 'udp dport 123 return' | cut -d: -f1)
mark_line=$(printf '%s' "$ntp" | grep -n 'meta mark set' | head -n 1 | cut -d: -f1)
check "выпуск NTP раньше разметки" "yes"     "$([ "$ntp_line" -lt "$mark_line" ] && echo yes || echo no)"

# Имена цепочек — не вкусовщина. «mark» и «output» — ключевые слова грамматики
# nft, и цепочка с таким именем валит разбор на самом объявлении. Файл
# применяется целиком, поэтому одна такая строка уносит весь набор: роутер
# остаётся вовсе без правил. Именно на этом xkop не работал на железе.
check "цепочка разметки не названа ключевым словом" "no" "$(has "$simple" 'chain mark ')"
check "цепочка вывода не названа ключевым словом" "no" "$(has "$fake" 'chain output ')"

# Выборочный перехват.
#
# Раньше метился весь трафик с LAN, и через userspace движка шёл в том числе
# тот, что уходит напрямую, — то есть весь интернет, включая замер скорости.
# На двухъядерном роутере это выглядит как «нестабильное соединение», хотя
# ничего не сломано. Так делает podkop, и в режиме поддельных адресов это
# возможно: маршрутизируемые имена уже получили адрес из своего диапазона.
picked=$(nft_ruleset "br-lan" "" 1 0 "198.18.0.0/15 149.154.160.0/20")
check "набор маршрутизируемых адресов появился" "yes" "$(has "$picked" 'set routed4')"
check "поддельный диапазон в наборе" "yes" "$(has "$picked" '198.18.0.0/15')"
check "подсеть Telegram в наборе" "yes" "$(has "$picked" '149.154.160.0/20')"
check "метится только он" "yes" "$(has "$picked" 'ip daddr @routed4 meta l4proto { tcp, udp } meta mark set')"

# Остальное обязано уходить мимо движка, иначе смысла в наборе нет.
after=$(printf '%s' "$picked" | sed -n '/chain mangle {/,/^    }/p' | grep -c 'meta mark set')
check "разметки всего одна, общей больше нет" "1" "$after"

# Без поддельных адресов имя видно только внутри соединения, и выборочно
# перехватывать нечем: метится всё, как раньше.
check "без списка адресов метится всё" "yes"     "$(has "$simple" 'meta l4proto { tcp, udp } meta mark set')"
check "и набора при этом нет" "no" "$(has "$simple" 'set routed4')"

# Собственный трафик движка пропускается не глядя.
#
# Без этого получается петля: движок отправляет соединение наружу, правило
# видит поддельный адрес и заворачивает пакет обратно в движок. Тысячи
# соединений за секунды, триста пятьдесят мегабайт памяти, OOM и перезагрузка.
# На живом роутере в conntrack было шесть тысяч записей на собственный адрес.
check "разметка пропускает трафик движка" "yes"     "$(has "$simple" "meta mark & $XKOP_NFT_ENGINE_MARK == $XKOP_NFT_ENGINE_MARK return")"
check "и цепочка вывода тоже" "yes"     "$(has "$fake" "meta mark & $XKOP_NFT_ENGINE_MARK == $XKOP_NFT_ENGINE_MARK return")"

# И пропуск обязан стоять раньше разметки, иначе он бесполезен.
skip_line=$(printf '%s' "$fake" | sed -n '/chain mangle_output/,/^    }/p'     | grep -n "$XKOP_NFT_ENGINE_MARK" | head -n 1 | cut -d: -f1)
mark_line=$(printf '%s' "$fake" | sed -n '/chain mangle_output/,/^    }/p'     | grep -n 'meta mark set' | head -n 1 | cut -d: -f1)
check "пропуск раньше разметки" "yes"     "$([ "$skip_line" -lt "$mark_line" ] && echo yes || echo no)"

# Метки не должны совпадать: одна отвечает «это надо перехватить»,
# другая — «это мы сами».
check "метки различаются" "yes"     "$([ "$XKOP_NFT_MARK" != "$XKOP_NFT_ENGINE_MARK" ] && echo yes || echo no)"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
