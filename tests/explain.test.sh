#!/bin/sh
# Разбор маршрута.
#
# Образцы строк сняты с живого движка Xray 26.3.27. Разделитель между входящим
# и исходящим у него значащий, и именно на нём держится ответ на вопрос
# «почему этот сайт ведёт себя так»: правило совпало или не совпало ни одно.

set -u

ROOT=${ROOT:-$(dirname "$0")/..}
LIB="$ROOT/xkop/files/usr/lib/xkop"
JQ=${JQ:-jq}

XKOP_LIB_DIR="$LIB"
# shellcheck source=/dev/null
. "$LIB/constants.sh"
XKOP_LIB_DIR="$LIB"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_ACCESS_LOG="$work/access.log"
XKOP_CONFIG_PATH="$work/config.json"

# shellcheck source=/dev/null
. "$LIB/logging.sh"
# shellcheck source=/dev/null
. "$LIB/explain.sh"

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

rule_line='2026/08/20 18:12:03.4 from tcp:192.168.1.50:41234 accepted tcp:example.com:443 [tproxy-in -> 🇩🇪 Германия(если нет ограничений)]'
default_line='2026/08/20 18:10:48.5 from tcp:127.0.0.1:61084 accepted tcp:openwrt.org:443 [probe-in >> direct]'
forced_line='2026/08/20 18:11:00.1 from tcp:127.0.0.1:61085 accepted tcp:forced.example:443 [probe-in ==> block]'

check "исходящее по правилу" "🇩🇪 Германия(если нет ограничений)" \
    "$(access_line_outbound "$rule_line")"
check "имя узла с пробелами не обрезано" "direct" "$(access_line_outbound "$default_line")"
check "принудительный исходящий" "block" "$(access_line_outbound "$forced_line")"

check "стрелка означает сработавшее правило" "rule" "$(access_line_reason "$rule_line")"
check "двойная стрелка — правило не совпало" "default" "$(access_line_reason "$default_line")"
check "толстая стрелка — назначено принудительно" "forced" "$(access_line_reason "$forced_line")"

printf '%s\n%s\n%s\n%s\n' "$rule_line" "$default_line" "$forced_line" "$rule_line" > "$XKOP_ACCESS_LOG"

check "строки про имя отобраны" "2" \
    "$(access_lines_for example.com | grep -c .)"
# Совпадение по ":имя:" не должно цеплять чужие имена, оканчивающиеся так же.
printf '%s\n' '2026/08/20 18:13:00.1 from tcp:1.2.3.4:1 accepted tcp:notexample.com:443 [tproxy-in -> direct]' >> "$XKOP_ACCESS_LOG"
check "чужое имя не попало" "2" "$(access_lines_for example.com | grep -c .)"

check "сводка считает по именам" "2" \
    "$(explain_recent 10 | jq -r '.domains[] | select(.domain == "example.com") | .requests')"
check "в сводке полное имя узла" "🇩🇪 Германия(если нет ограничений)" \
    "$(explain_recent 10 | jq -r '.domains[] | select(.domain == "example.com") | .outbound')"
check "напрямую тоже видно" "direct" \
    "$(explain_recent 10 | jq -r '.domains[] | select(.domain == "openwrt.org") | .outbound')"

# Подрезка: файл держит открытым движок, поэтому усечение идёт на месте.
XKOP_ACCESS_LOG_MAX_KB=1
i=0
: > "$XKOP_ACCESS_LOG"
while [ "$i" -lt 200 ]; do
    echo "2026/08/20 18:20:00.0 from tcp:192.168.1.$i:1 accepted tcp:host$i.example:443 [tproxy-in -> direct]" \
        >> "$XKOP_ACCESS_LOG"
    i=$((i + 1))
done
before=$(wc -c < "$XKOP_ACCESS_LOG")
access_trim
after=$(wc -c < "$XKOP_ACCESS_LOG")
check "разросшийся журнал подрезан" "yes" "$([ "$after" -lt "$before" ] && echo yes || echo no)"
check "и не обнулён" "yes" "$([ "$after" -gt 0 ] && echo yes || echo no)"

# --- адрес имени и перехват -------------------------------------------------
#
# Разбор маршрута отвечал только «правило совпало / не совпало». Этого мало:
# правило может не совпасть, а сайт при этом жить на адресе, до которого
# провайдер не даёт дойти. На живом роутере это стоило трёх часов и дампа
# трафика, хотя ответ - две строки: адрес и есть ли он в наборе.

check "поддельный адрес опознан" "yes"     "$(explain_is_fake 198.18.4.7 && echo yes || echo no)"
check "вторая половина диапазона тоже" "yes"     "$(explain_is_fake 198.19.250.116 && echo yes || echo no)"
check "настоящий адрес не поддельный" "no"     "$(explain_is_fake 151.101.67.6 && echo yes || echo no)"

# Опознание держится на двух октетах, а не на разборе маски. Если константа
# когда-нибудь сменится, упасть должно здесь.
check "диапазон FakeIP тот, на который рассчитано опознание" "198.18.0.0/15"     "$XKOP_FAKEIP_RANGE"

# Резолвер и ядро подменены: проверяется не сеть, а то, что ответ собран
# и что «в наборе» и «поддельный» не путаются местами.
nslookup() {
    echo "Server:  127.0.0.1"
    echo "Address: 127.0.0.1:53"
    echo ""
    echo "Name:    $1"
    echo "Address: 151.101.67.6"
    echo "Address: 198.18.4.7"
}
nft_routed_contains() {
    [ "$1" = "198.18.4.7" ]
}

addresses=$(explain_addresses example.com)

check "адреса собраны, служебная строка отброшена" "2"     "$(printf '%s' "$addresses" | "$JQ" 'length')"
check "настоящий адрес вне перехвата" "false"     "$(printf '%s' "$addresses" | "$JQ" -c '.[0].intercepted')"
check "и он не поддельный" "false"     "$(printf '%s' "$addresses" | "$JQ" -c '.[0].fake')"
check "поддельный опознан и перехватывается" "true"     "$(printf '%s' "$addresses" | "$JQ" -c '.[1].fake and .[1].intercepted')"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
