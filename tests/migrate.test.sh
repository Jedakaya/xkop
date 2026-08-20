#!/bin/sh
# Перенос пользовательских списков из podkop.
#
# Образец взят с живого роутера, где podkop настраивался годами: три десятка
# доменов и подсетей, вбитых по одному по мере того, как что-то не открывалось.
# Заново такое не вводят - половину просто не вспомнят.
#
# Отдельно проверяется отбраковка поддельных адресов: в списке подсетей рядом
# с настоящими сетями лежали записи вида 198.18.2.109 - выданные когда-то
# FakeIP-адреса. У нас свой пул поддельных, и чужие в правилах означают
# перехват того, чего не существует.

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

XKOP_CONFIG=xkop
export XKOP_CONFIG

# uci подменён файлами: проверяется перенос, а не работа uci.
: > "$work/written"

uci() {
    case "$1" in
        -q)
            shift
            uci "$@"
            return $?
            ;;
        show)
            cat "$work/podkop.show" 2> /dev/null
            ;;
        get)
            local key="$2"
            grep "^$key=" "$work/podkop.values" 2> /dev/null | head -n 1 | cut -d= -f2-
            ;;
        add_list)
            printf '%s\n' "$2" >> "$work/written"
            ;;
        delete)
            printf 'delete %s\n' "$2" >> "$work/written"
            ;;
        commit) ;;
    esac
}

cat > "$work/podkop.show" << 'EOF'
podkop.settings=settings
podkop.main=section
podkop.NetBird=section
EOF

# Списки один в один с живого роутера, включая поддельные адреса и мусор.
cat > "$work/podkop.values" << 'EOF'
podkop.main.user_domains=proton.me aka.ms go.microsoft.com update.ahnlab.com vscode-unpkg.net
podkop.main.user_subnets=198.18.0.58 172.67.209.104 8.6.112.6 198.18.2.109 13.107.6.0/24 151.101.0.0/16 69.46.46.51 198.18.2.252
podkop.NetBird.user_domains=panel.birdforge.art
podkop.NetBird.user_subnets=100.127.213.128
EOF

# shellcheck source=/dev/null
. "$LIB/migrate.sh"

check "podkop виден" "yes" "$(migrate_podkop_present && echo yes || echo no)"
check "секции найдены" "main NetBird" "$(migrate_podkop_sections | tr '\n' ' ' | sed 's/ $//')"

check "домены собраны из всех секций" "6" "$(migrate_podkop_domains | wc -l | tr -d ' ')"
check "домен из второй секции на месте" "yes" \
    "$(migrate_podkop_domains | grep -q '^panel.birdforge.art$' && echo yes || echo no)"

check "подсети собраны без поддельных" "6" "$(migrate_podkop_subnets | wc -l | tr -d ' ')"
check "поддельный адрес отброшен" "no" \
    "$(migrate_podkop_subnets | grep -q '^198\.18\.' && echo yes || echo no)"
check "настоящая сеть на месте" "yes" \
    "$(migrate_podkop_subnets | grep -q '^13\.107\.6\.0/24$' && echo yes || echo no)"
check "одиночный адрес тоже переносится" "yes" \
    "$(migrate_podkop_subnets | grep -q '^69\.46\.46\.51$' && echo yes || echo no)"
check "отброшенные сосчитаны" "3" "$(migrate_podkop_skipped)"

# --- запись в профиль -------------------------------------------------------

count=$(migrate_podkop_apply blocked_ru)
check "перенесено записей" "12" "$count"
check "прежние списки очищены перед записью" "2" \
    "$(grep -c '^delete ' "$work/written")"
check "домен ушёл в профиль" "yes" \
    "$(grep -q '^xkop.blocked_ru.domain=proton.me$' "$work/written" && echo yes || echo no)"
check "подсеть ушла в профиль" "yes" \
    "$(grep -q '^xkop.blocked_ru.subnet=13.107.6.0/24$' "$work/written" && echo yes || echo no)"

# Повторный запуск обязан давать то же самое, а не удваивать записи.
: > "$work/written"
count=$(migrate_podkop_apply blocked_ru)
check "повторный перенос даёт то же число" "12" "$count"

# Пустой podkop - не отказ, а «нечего переносить».
: > "$work/podkop.values"
: > "$work/podkop.show"
check "без podkop перенос не выполняется" "1" \
    "$(migrate_podkop_apply blocked_ru > /dev/null 2>&1; echo $?)"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
