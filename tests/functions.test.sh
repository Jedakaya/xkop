#!/bin/sh
# Вызванная функция обязана существовать.
#
# В shell вызов несуществующей функции — не ошибка разбора и не ошибка при
# загрузке файла: команда просто не находится в момент выполнения. Если это
# происходит в фоновом задании или в редкой ветке, никто ничего не замечает.
#
# Так фоновое обновление подсетей звало lists_subnets_update_changed, которой
# нет вовсе: задание падало молча, подсети после старта не обновлялись никогда,
# и на роутере три категории просто отсутствовали. До этого так же тихо
# вызывались nodes_count и engine_version.
#
# Ищем только позицию команды: первое слово строки либо слово сразу после
# if, &&, ||, then, else, do, ; или (. Иначе в список попадут имена полей JSON
# и ключей uci, и проверка начнёт гадать вместо того, чтобы проверять.

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

# Имена в позиции команды, с нашими приставками.
calls() {
    awk '
        function is_ours(w) {
            return w ~ /^(xkop|lists|nodes|canary|config|subscription|service|dnsmasq|nft|explain|userlist|update|diag|cmd|engine|cron|recovery|panel|access|metrics|version)_[a-z0-9_]+$/
        }
        /^[[:space:]]*#/ { next }
        # Ветка case — это метка, а не вызов: "subscription_refresh)" стоит
        # в позиции команды и ею не является.
        /^[[:space:]]*[a-z_|* ]+\)[[:space:]]*$/ { next }
        {
            expect = 1
            for (i = 1; i <= NF; i++) {
                w = $i
                gsub(/[();|&]+$/, "", w)
                if (expect && is_ours(w)) print w
                expect = ($i ~ /^(if|then|else|do|&&|\|\||;)$/ || $i ~ /[;&|]$/)
            }
        }
    ' "$@" | sort -u
}

defs() {
    grep -hoE '^[a-z_][a-z0-9_]*\(\)' "$@" | tr -d '()' | sort -u
}

# shellcheck disable=SC2086
set -- $LIB/*.sh "$ROOT/xkop/files/usr/bin/xkop"
defined=$(defs "$@")
called=$(calls "$@")

# Функции самой OpenWrt: приходят из /lib/functions.sh, объявлять их у себя
# незачем и нельзя.
external='config_load config_get config_get_bool config_set config_foreach
config_list_foreach config_list_add config_rename'

missing=""
for name in $called; do
    printf '%s\n' "$defined" | grep -qx "$name" && continue
    case " $(echo $external) " in *" $name "*) continue ;; esac
    missing="$missing $name"
done

check "все вызванные функции объявлены" "" "$missing"

# Проверка обязана ловить, а не только соглашаться.
probe=$(mktemp)
cat > "$probe" << 'PROBE'
lists_real() { echo real; }
lists_real
if lists_ghost; then echo нет; fi
echo "в строке lists_notacall не вызов"
jq -n '{lists_field: 1}'
PROBE

ghost=""
for name in $(calls "$probe"); do
    printf '%s\n' "$(defs "$probe")" | grep -qx "$name" && continue
    ghost="$ghost $name"
done
rm -f "$probe"

check "и ловит только настоящий вызов" "lists_ghost" "$(echo $ghost)"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
