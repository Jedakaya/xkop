#!/bin/sh
# Установщик обязан привезти всё, что нужно для запуска.
#
# Забытая в списке библиотека означает не «без одной возможности», а команду,
# которая не стартует вовсе: /usr/bin/xkop подключает их все. Такую ошибку
# на роутере видно поздно и больно, а здесь — сразу.

set -u

ROOT=${ROOT:-$(dirname "$0")/..}

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

# Что лежит в репозитории.
have=$(ls "$ROOT/xkop/files/usr/lib/xkop" | sort | tr '\n' ' ' | sed 's/ *$//')

# Что перечислено в установщике.
listed=$(sed -n '/XKOP_LIBS="/,/"$/p' "$ROOT/install.sh" \
    | sed -e 's/^ *XKOP_LIBS="//' -e 's/"$//' \
    | tr ' \n' '\n\n' | grep -v '^$' | sort | tr '\n' ' ' | sed 's/ *$//')

check "установщик знает про все библиотеки" "$have" "$listed"

# То же для точек панели.
panel_have=$(ls "$ROOT/client-panel/cgi-bin" | sort | tr '\n' ' ' | sed 's/ *$//')
panel_listed=$(sed -n 's/^ *for endpoint in \(.*\) \\$/\1/p;s/^ *\(routes route-set.*\); do$/\1/p' "$ROOT/install.sh" \
    | tr ' \n' '\n\n' | grep -v '^$' | sort | tr '\n' ' ' | sed 's/ *$//')

check "установщик знает про все точки панели" "$panel_have" "$panel_listed"

# Файл службы без пакета тоже надо привезти: иначе команды есть, а запускать
# нечем.
check "файл службы скачивается" "yes" \
    "$(grep -q 'files/etc/init.d/xkop' "$ROOT/install.sh" && echo yes || echo no)"

# Каждая библиотека, которую подключает /usr/bin/xkop, обязана существовать.
missing=""
for lib in $(sed -n 's|^\. "\$XKOP_LIB_DIR/\(.*\)"$|\1|p' "$ROOT/xkop/files/usr/bin/xkop"); do
    [ -f "$ROOT/xkop/files/usr/lib/xkop/$lib" ] || missing="$missing $lib"
done
check "все подключаемые библиотеки существуют" "" "$missing"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
