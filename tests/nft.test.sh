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
    "$(has "$simple" 'chain divert')"

# Приоритеты: разметка должна случиться раньше разворота, иначе метку некому
# будет увидеть.
mark_priority=$(printf '%s' "$simple" | sed -n 's/.*hook prerouting priority \(-[0-9]*\).*/\1/p' | head -n 1)
divert_priority=$(printf '%s' "$simple" | sed -n 's/.*hook prerouting priority \(-[0-9]*\).*/\1/p' | tail -n 1)
check "разметка раньше разворота" "yes" \
    "$([ "$mark_priority" -lt "$divert_priority" ] && echo yes || echo no)"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
