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
panel_listed=$(sed -n 's/^PANEL_CGI_FILES="\(.*\)"$/\1/p' "$ROOT/install.sh" \
    | tr ' \n' '\n\n' | grep -v '^$' | sort | tr '\n' ' ' | sed 's/ *$//')

check "установщик знает про все точки панели" "$panel_have" "$panel_listed"

# То же для LuCI. Забытый вид означает пустую вкладку в «Сервисы», а забытое
# меню — отсутствие самой вкладки при полностью разложенных файлах. Ровно это
# и случилось на первой установке с ветки.
luci_have=$(ls "$ROOT/luci-app-xkop/htdocs/luci-static/resources/view/xkop" | sort | tr '\n' ' ' | sed 's/ *$//')
luci_listed=$(sed -n 's/^ *XKOP_LUCI_VIEWS="\(.*\)"$/\1/p' "$ROOT/install.sh" \
    | tr ' \n' '\n\n' | grep -v '^$' | sort | tr '\n' ' ' | sed 's/ *$//')

check "установщик знает про все виды LuCI" "$luci_have" "$luci_listed"

check "установщик кладёт меню LuCI" "yes" \
    "$(grep -q 'luci/menu.d' "$ROOT/install.sh" && echo yes || echo no)"
check "установщик кладёт права rpcd" "yes" \
    "$(grep -q 'rpcd/acl.d' "$ROOT/install.sh" && echo yes || echo no)"

# Меню и права кэшируются: без сброса вкладка не появится до перезагрузки.
check "установщик сбрасывает кэш LuCI" "yes" \
    "$(grep -q 'luci-indexcache' "$ROOT/install.sh" && echo yes || echo no)"

# Файлы панели никого не обслуживают сами по себе.
check "установщик поднимает панель" "yes" \
    "$(grep -q 'listen_http=' "$ROOT/install.sh" && echo yes || echo no)"

# Лимит открытых файлов у движка.
#
# Без него procd отдаёт системный умолчальный, на OpenWrt это 1024. Через
# движок идёт весь трафик роутера, каждое соединение — дескриптор, и они
# кончаются за минуты: движок пишет «accept4: too many open files» и перестаёт
# принимать даже собственный эндпоинт метрик. Снаружи это выглядит как что
# угодно, только не как лимит, и стоило половины дня отладки на железе.
check "движку задан лимит дескрипторов" "yes"     "$(grep -q 'limits nofile' "$ROOT/xkop/files/etc/init.d/xkop" && echo yes || echo no)"

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
