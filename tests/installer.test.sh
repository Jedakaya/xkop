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

# Переменная не должна использоваться раньше, чем задана.
#
# Установщик работает с `set -u`, поэтому такая ошибка не видна ни `sh -n`,
# ни глазами: она вылезает только при запуске, на роутере, и обрывает установку
# на середине. Именно так уехал блок «возвращаем службу как было» — вставился
# на 360 строк выше места, где переменная появляется.
#
# Смотрим только то, что вне тел функций: внутри функции переменная может
# использоваться и раньше присваивания, потому что вызовут её позже.
early=$(awk '
    # Однострочная функция открывается и закрывается на той же строке,
    # и принимать её за начало тела значит объявить весь остаток файла телом.
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{.*\}[[:space:]]*$/ { next }
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{/ { infunc = 1; next }
    infunc && /^\}/                    { infunc = 0; next }
    infunc                             { next }
    {
        line = $0
        if (match(line, /^[[:space:]]*(export )?[A-Z][A-Z0-9_]*=/)) {
            name = line
            sub(/^[[:space:]]*(export )?/, "", name)
            sub(/=.*/, "", name)
            if (!(name in setat)) setat[name] = NR
        }
        rest = line
        while (match(rest, /[$]\{?[A-Z][A-Z0-9_]+/)) {
            name = substr(rest, RSTART, RLENGTH)
            sub(/^[$]\{?/, "", name)
            if (!(name in useat)) useat[name] = NR
            rest = substr(rest, RSTART + RLENGTH)
        }
    }
    END {
        for (n in useat) {
            if (n == "XKOP_REPO" || n == "XKOP_REF" || n == "XKOP_FROM_BRANCH" ||
                n == "XKOP_NO_ENGINE" || n == "XKOP_KEEP_PODKOP" || n == "GITHUB_TOKEN" ||
                n == "PATH" || n == "TMPDIR" || n == "IFS" || n == "OPENWRT_ARCH") continue
            if (!(n in setat) || setat[n] > useat[n]) printf "%s ", n
        }
    }
' "$ROOT/install.sh")

check "переменные задаются раньше, чем используются" "" "$(echo $early)"

# Проверка обязана ловить, а не только соглашаться. Иначе она просто мебель.
broken="$(mktemp)"
cat > "$broken" << 'BROKEN'
#!/bin/sh
set -u
say() { echo "$*"; }
if [ "$LATE" -eq 1 ]; then say "рано"; fi
LATE=0
BROKEN
caught=$(awk '
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{.*\}[[:space:]]*$/ { next }
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{/ { infunc = 1; next }
    infunc && /^\}/                    { infunc = 0; next }
    infunc                             { next }
    {
        if (match($0, /^[[:space:]]*(export )?[A-Z][A-Z0-9_]*=/)) {
            name = $0
            sub(/^[[:space:]]*(export )?/, "", name)
            sub(/=.*/, "", name)
            if (!(name in setat)) setat[name] = NR
        }
        rest = $0
        while (match(rest, /[$]\{?[A-Z][A-Z0-9_]+/)) {
            name = substr(rest, RSTART, RLENGTH)
            sub(/^[$]\{?/, "", name)
            if (!(name in useat)) useat[name] = NR
            rest = substr(rest, RSTART + RLENGTH)
        }
    }
    END { for (n in useat) if (!(n in setat) || setat[n] > useat[n]) printf "%s ", n }
' "$broken")
rm -f "$broken"

check "и ловит, когда порядок нарушен" "LATE" "$(echo $caught)"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
