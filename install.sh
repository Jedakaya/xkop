#!/bin/sh
# Установка xkop. Запускается НА РОУТЕРЕ.
#
#   sh <(wget -O - https://github.com/Jedakaya/xkop/releases/latest/download/install.sh)
#
# Именно из релиза: raw.githubusercontent отдаёт ветку с пограничного кэша
# и параметры запроса игнорирует, поэтому исправленный скрипт ещё какое-то
# время приезжает старым. Файл релиза привязан к тегу и подменён быть не может.
#
# Ставит пакетами: пакетный менеджер знает версию, умеет обновить и умеет
# удалить. Обновление потом — одной командой:
#
#   xkop update
#
# Если релиза ещё нет или под эту архитектуру пакета не собрано, установщик
# кладёт файлы прямо с ветки. Это путь для разработки: он рабочий, но версии
# у него нет, только хэш коммита.
#
# Обращение с пакетным менеджером, местом, часами и панелью перенято из
# podkop-forge целиком: там каждое правило куплено отказом на живом роутере,
# и переоткрывать их заново — платить ту же цену второй раз. Что именно
# куплено, сказано в комментариях по месту.
#
# Переменные, все необязательные:
#   XKOP_REPO=Jedakaya/xkop    XKOP_REF=main
#   XKOP_FROM_BRANCH=1         не смотреть релизы, ставить с ветки
#   XKOP_NO_ENGINE=1           не трогать движок
#   GITHUB_TOKEN=...           если репозиторий закрыт

set -u

XKOP_REPO=${XKOP_REPO:-Jedakaya/xkop}
XKOP_REF=${XKOP_REF:-main}
XKOP_LIB_DIR=/usr/lib/xkop
PANEL_ROOT=/www-xkop
PANEL_PORT=8090
PANEL_UHTTPD_SECTION=xkop
WORK=/tmp/xkop-install

say() { echo; echo "== $*"; }
note() { echo "-- $*"; }
warn() { echo "!! $*"; }
die() { echo "!! $*" >&2; exit 1; }

PKG_IS_APK=0
command -v apk > /dev/null 2>&1 && PKG_IS_APK=1

# --- примитивы ------------------------------------------------------------

# busybox сменил договорённость о вызове timeout: старые сборки ждут
# `timeout -t СЕК КОМАНДА`, новые `timeout СЕК КОМАНДА`. Ошибка в догадке
# не видна: старая сборка примет число за имя программы. Поэтому обе формы
# сначала пробуются на пустой команде.
run_bounded() {
    secs="$1"
    shift

    if timeout 1 true > /dev/null 2>&1; then
        timeout "$secs" "$@" > /dev/null 2>&1
        return 0
    fi

    if timeout -t 1 true > /dev/null 2>&1; then
        timeout -t "$secs" "$@" > /dev/null 2>&1
        return 0
    fi

    "$@" > /dev/null 2>&1 &
    bounded_pid=$!
    bounded_waited=0
    while [ "$bounded_waited" -lt "$secs" ] && kill -0 "$bounded_pid" 2> /dev/null; do
        sleep 1
        bounded_waited=$((bounded_waited + 1))
    done
    kill "$bounded_pid" 2> /dev/null

    return 0
}

# На свежей OpenWrt curl нет, есть только wget. Требовать curl до того, как
# отработает пакетный менеджер, значит отказать ровно тому роутеру, ради
# которого этот скрипт и написан.
download() {
    if command -v curl > /dev/null 2>&1; then
        curl -fsSL --max-time 300 -o "$2" "$1"
    else
        wget -q -O "$2" "$1"
    fi
}

# Перенято у podkop, где куплено настоящими отказами: когда провайдер травит
# DNS, GitHub перестаёт резолвиться, и любая загрузка падает с причиной,
# которая называет не ту проблему. Резолвер musl читает /etc/hosts раньше DNS.
fix_github_dns() {
    marker="# xkop: github DNS fallback"
    broken=0

    grep -qF "$marker" /etc/hosts 2> /dev/null && return 0
    for host in raw.githubusercontent.com api.github.com github.com; do
        nslookup "$host" > /dev/null 2>&1 || broken=1
    done
    [ "$broken" -eq 0 ] && return 0

    note "домены GitHub не резолвятся, добавляю записи в /etc/hosts"
    {
        echo "$marker"
        echo "20.205.243.166 github.com"
        echo "20.205.243.168 api.github.com"
        echo "20.205.243.165 codeload.github.com"
        echo "185.199.108.133 raw.githubusercontent.com"
        echo "185.199.109.133 raw.githubusercontent.com"
        echo "185.199.110.133 raw.githubusercontent.com"
        echo "185.199.111.133 raw.githubusercontent.com"
        echo "185.199.108.133 objects.githubusercontent.com"
        echo "185.199.109.133 objects.githubusercontent.com"
        echo "185.199.108.133 release-assets.githubusercontent.com"
        echo "185.199.109.133 release-assets.githubusercontent.com"
    } >> /etc/hosts

    /etc/init.d/dnsmasq restart > /dev/null 2>&1
}

fetch_repo_file() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsSL --max-time 120 \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github.raw" \
            -o "$2" "https://api.github.com/repos/$XKOP_REPO/contents/$1?ref=$SHA" 2> /dev/null
    else
        download "https://raw.githubusercontent.com/$XKOP_REPO/$SHA/$1" "$2"
    fi
}

# --- часы -----------------------------------------------------------------

# `date -r ФАЙЛ` есть не во всякой сборке busybox, поэтому единственным
# способом узнать время правки он быть не может.
file_mtime() {
    [ -e "$1" ] || return 0

    value=$(date -r "$1" +%s 2> /dev/null)
    case "$value" in
        '' | *[!0-9]*) value=$(find "$1" -maxdepth 0 -printf '%T@' 2> /dev/null | cut -d. -f1) ;;
    esac
    case "$value" in
        '' | *[!0-9]*) return 0 ;;
    esac

    echo "$value"
}

# Сравнение идёт с моментом, который заведомо уже прошёл, а не с вшитым годом:
# вшитый устаревает в день написания.
clock_is_plausible() {
    now=$(date +%s 2> /dev/null)
    case "$now" in
        '' | *[!0-9]*) return 1 ;;
    esac

    ref=$(file_mtime /usr/bin/xkop)
    [ -z "$ref" ] && ref=$(file_mtime /etc/openwrt_release)
    # Нет опоры — нет мнения, и это не должно стоить минуты ожидания.
    [ -z "$ref" ] && return 0

    [ "$now" -ge "$ref" ]
}

# `ntpd -q` возвращается только когда часы действительно выставлены, и своего
# ограничения не имеет: недоступные серверы вешают его навсегда. Ожидание
# ограничено и только когда часы заведомо не выставлены — иначе HTTPS-загрузки
# отваливаются по проверке сертификата, а причина называется не та.
sync_time() {
    [ -x /usr/sbin/ntpd ] || return 0
    clock_is_plausible && return 0

    note "часы не выставлены, жду синхронизацию (до 60 с)"
    run_bounded 60 /usr/sbin/ntpd -q -p 194.190.168.1 -p 216.239.35.0 \
        -p 216.239.35.4 -p 162.159.200.1 -p 162.159.200.123

    clock_is_plausible || warn "время синхронизировать не удалось, HTTPS-загрузки могут не пройти"
    return 0
}

# --- место ----------------------------------------------------------------

overlay_free_kb() {
    df -k /overlay 2> /dev/null | awk 'NR==2 {print $4}'
}

# Печатается только когда установка отклонена: гадать, что удалить, — худшая
# часть упирания в полный overlay, поэтому кандидаты называются.
report_flash_usage() {
    echo
    note "что занимает место на /overlay (топ-10):"
    du -sk /overlay/upper/* 2> /dev/null | sort -rn | head -10 | while read -r size path; do
        echo "     ${size} КБ  $path"
    done
}

# Освобождает флэш, который целиком кэш: ничего из этого не нужно для работы
# роутера и всё восстанавливается по требованию. /var на OpenWrt — символьная
# ссылка в tmpfs, поэтому кэш apk и списки opkg под ним флэша не стоят вовсе:
# их вычистка не освобождает ничего, зато заставляет заново качать весь индекс,
# с чего в podkop и начались отказы из-за одного капризного фида.
reclaim_flash_space() {
    before=$(overlay_free_kb)

    rm -rf /usr/lib/opkg/lists/* 2> /dev/null
    rm -rf /usr/lib/opkg/tmp/* 2> /dev/null
    rm -f /var/log/*.old /var/log/*.gz 2> /dev/null

    after=$(overlay_free_kb)
    [ -n "$before" ] && [ -n "$after" ] || return 0
    freed=$((after - before))
    [ "$freed" -gt 0 ] && note "освобождено кэша: ${freed} КБ"
    return 0
}

# Место под пакет проверяет сам менеджер сухим прогоном. Он учитывает место,
# которое вернёт удаляемая старая версия, — сравнение размеров этого не умеет
# и в podkop отказывало роутерам, которым места хватало.
pkg_install_would_succeed() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        out=$(apk add --allow-untrusted --upgrade --simulate "$1" 2>&1)
    else
        out=$(opkg install --noaction "$1" 2>&1)
    fi
    rc=$?

    [ $rc -eq 0 ] && return 0

    # Менеджер, не знающий флага, не имеет права читаться как «не поместится»:
    # отказ по этой причине блокировал бы любое обновление.
    if printf '%s' "$out" | grep -qiE 'unrecognized option|invalid option|unknown option|usage:'; then
        return 0
    fi

    printf '%s\n' "$out" | head -n 3
    return 1
}

# Неудачная установка не имеет права ломать менеджер пакетов целиком.
#
# apk записывает пакет в /etc/apk/world — список «этот пакет мне нужен» —
# раньше, чем завершит установку. Если установка падает (не хватило места),
# запись остаётся, и дальше apk на КАЖДОЙ операции требует пакет, которого
# нет: "unable to select packages: xray-xkop (no such package): required by:
# world[...]". Роутер после этого не может поставить вообще ничего — ни наше,
# ни чужое, — и связи с xkop у этого уже не видно.
#
# Куплено на живом роутере: движок не поместился, и человек потом не смог
# вернуть себе podkop, потому что apk отказывал на всём подряд.
#
# Лечится откатом списка: снимок до установки, возврат при неудаче.
pkg_world_snapshot() {
    [ "$PKG_IS_APK" -eq 1 ] || return 0
    [ -f /etc/apk/world ] || return 0
    cp /etc/apk/world "$WORK/world.before" 2> /dev/null || true
}

pkg_world_restore() {
    [ "$PKG_IS_APK" -eq 1 ] || return 0
    [ -f "$WORK/world.before" ] || return 0

    cmp -s "$WORK/world.before" /etc/apk/world 2> /dev/null && return 0

    cp "$WORK/world.before" /etc/apk/world 2> /dev/null || return 0
    note "список пакетов apk возвращён к прежнему: неудачная установка его засоряет"
}

pkg_install_file() {
    file="$1"
    [ -s "$file" ] || return 1

    if ! pkg_install_would_succeed "$file"; then
        warn "$(basename "$file") не встанет: менеджер отказал на сухом прогоне"
        report_flash_usage
        return 2
    fi

    if [ "$PKG_IS_APK" -eq 1 ]; then
        pkg_world_snapshot
        if apk add --allow-untrusted --upgrade "$file" > /dev/null 2>&1; then
            return 0
        fi
        pkg_world_restore
        return 1
    fi

    opkg install "$file" > /dev/null 2>&1
}

# Засор, оставшийся от прошлых попыток, — в том числе от прошлых версий этого
# же установщика. Пока он там, не встанет ничего, поэтому чистится до всего
# остального и без вопросов: записи про наши пакеты в world при отсутствующих
# файлах не значат ничего, кроме брошенной установки.
pkg_world_repair() {
    [ "$PKG_IS_APK" -eq 1 ] || return 0
    [ -f /etc/apk/world ] || return 0

    apk add --simulate --no-interactive > /dev/null 2>&1 && return 0

    # Имена всех наших пакетов содержат xkop и ничьи больше: xray-xkop,
    # luci-app-xkop, сам xkop. Запись в world бывает с ограничением по
    # контрольной сумме - "xray-xkop>Q127DAn...=", - поэтому ищется вхождение,
    # а не полное имя.
    grep -q 'xkop' /etc/apk/world 2> /dev/null || return 0

    warn "apk не может выполнить ни одной операции: в списке пакетов висит наша брошенная запись"
    sed -i '/xkop/d' /etc/apk/world 2> /dev/null || return 0

    if apk add --simulate --no-interactive > /dev/null 2>&1; then
        note "запись убрана, apk снова работает"
    else
        warn "запись убрана, но apk всё ещё отказывает — причина не в ней"
    fi
}

# --- индекс пакетов -------------------------------------------------------

pkg_list_update_raw() {
    : > "$1"
    if [ "$PKG_IS_APK" -eq 1 ]; then
        run_bounded 180 sh -c "apk update > '$1' 2>&1"
    else
        run_bounded 180 sh -c "opkg update > '$1' 2>&1"
    fi
}

# Одного недоступного фида хватает, чтобы менеджер вышел с ошибкой: один сброс
# TLS на репозитории телефонии обрывал установку целиком, хотя остальные
# десять тысяч пакетов проиндексированы. xkop ставится из файла, скачанного
# отдельно, поэтому неполный индекс — не причина останавливаться.
pkg_index_is_usable() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        count=$(printf '%s' "$1" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) distinct packages available.*/\1/p' | tail -n 1)
        [ -n "$count" ] && [ "$count" -gt 0 ]
        return $?
    fi
    ls /var/opkg-lists/* > /dev/null 2>&1 || ls /usr/lib/opkg/lists/* > /dev/null 2>&1
}

pkg_list_update() {
    outfile="/tmp/xkop-pkglist.$$"

    pkg_list_update_raw "$outfile"
    out=$(cat "$outfile" 2> /dev/null)
    rm -f "$outfile"
    [ -n "$out" ] && return 0

    # «Operation not permitted» здесь означает IPv6, а не права.
    if printf '%s' "$out" | grep -qi "Operation not permitted"; then
        note "похоже на IPv6, временно выключаю его и повторяю"
        sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null 2>&1
        sysctl -w net.ipv6.conf.default.disable_ipv6=1 > /dev/null 2>&1

        pkg_list_update_raw "$outfile"
        out=$(cat "$outfile" 2> /dev/null)
        rm -f "$outfile"

        sysctl -w net.ipv6.conf.all.disable_ipv6=0 > /dev/null 2>&1
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 > /dev/null 2>&1
        [ -n "$out" ] && return 0
    fi

    if pkg_index_is_usable "$out"; then
        note "часть репозиториев недоступна, но индекс пригоден — продолжаю"
        return 0
    fi

    return 1
}

pkg_add() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add --no-interactive "$1" > /dev/null 2>&1
    else
        opkg install "$1" > /dev/null 2>&1
    fi
}

# --- снятие установок мимо менеджера --------------------------------------

# Установка с ветки кладёт те же пути, что и пакет, но менеджер о них не знает.
# Поставить пакет поверх — это конфликт файлов, а не обновление.
file_unowned() {
    [ -e "$1" ] || return 1
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk info --who-owns "$1" > /dev/null 2>&1 && return 1
    elif command -v opkg > /dev/null 2>&1; then
        opkg search "$1" 2> /dev/null | grep -q . && return 1
    fi
    return 0
}

branch_install_remove() {
    note "убираю установку с ветки: пакет положит те же файлы"
    [ -x /etc/init.d/xkop ] && /etc/init.d/xkop stop > /dev/null 2>&1
    rm -rf /usr/lib/xkop /www/luci-static/resources/view/xkop
    rm -f /usr/bin/xkop /etc/init.d/xkop
    rm -f /usr/share/luci/menu.d/luci-app-xkop.json \
        /usr/share/rpcd/acl.d/luci-app-xkop.json
    # /etc/config/xkop остаётся: это единственный файл, где не наше состояние.
}

# --- панель ---------------------------------------------------------------

# Адрес выводится, а не вшивается: dnsmasq отдаёт <имя>.<домен>, и «openwrt.lan»
# верно ровно до первой смены имени роутера. В OpenWrt 25.12 адрес LAN лежит
# в CIDR, из-за чего в ссылку попадало http://192.168.0.1/24:8090.
panel_address() {
    host=$(uci -q get system.@system[0].hostname 2> /dev/null)
    [ -z "$host" ] && host=$(cat /proc/sys/kernel/hostname 2> /dev/null)
    domain=$(uci -q get dhcp.@dnsmasq[0].domain 2> /dev/null)
    [ -z "$domain" ] && domain="lan"
    lan_ip=$(uci -q get network.lan.ipaddr 2> /dev/null)
    lan_ip="${lan_ip%%/*}"

    [ -n "$host" ] && echo "http://$(echo "$host" | tr 'A-Z' 'a-z').$domain:$PANEL_PORT"
    [ -n "$lan_ip" ] && echo "http://$lan_ip:$PANEL_PORT"
    return 0
}

configure_panel_uhttpd() {
    uci -q delete uhttpd."$PANEL_UHTTPD_SECTION"
    uci set uhttpd."$PANEL_UHTTPD_SECTION"=uhttpd
    uci add_list uhttpd."$PANEL_UHTTPD_SECTION".listen_http="0.0.0.0:$PANEL_PORT"
    uci set uhttpd."$PANEL_UHTTPD_SECTION".home="$PANEL_ROOT"
    uci set uhttpd."$PANEL_UHTTPD_SECTION".cgi_prefix="/cgi-bin"
    uci set uhttpd."$PANEL_UHTTPD_SECTION".index_page="index.html"
    uci set uhttpd."$PANEL_UHTTPD_SECTION".script_timeout="60"
    uci set uhttpd."$PANEL_UHTTPD_SECTION".network_timeout="30"
    uci commit uhttpd

    /etc/init.d/uhttpd restart > /dev/null 2>&1
}

PANEL_CGI_FILES="_common auth status subscription-set subscription-update routes route-set node-select explain"

download_panel_into() {
    dest="$1"
    mkdir -p "$dest/cgi-bin" || return 1

    fetch_repo_file "client-panel/index.html" "$dest/index.html" || return 1
    [ -s "$dest/index.html" ] || return 1

    for name in $PANEL_CGI_FILES; do
        fetch_repo_file "client-panel/cgi-bin/$name" "$dest/cgi-bin/$name" || return 1
        [ -s "$dest/cgi-bin/$name" ] || return 1
    done

    return 0
}

# Собирается в RAM и переезжает только когда приехал каждый файл: загрузка,
# умершая на середине, не имеет права оставить панель наполовину заменённой.
install_client_panel() {
    staging="/tmp/xkop-panel.$$"
    rm -rf "$staging"

    if ! download_panel_into "$staging"; then
        rm -rf "$staging"
        warn "панель не скачалась целиком, xkop это переживёт"
        return 1
    fi

    mkdir -p "$PANEL_ROOT" || { rm -rf "$staging"; return 1; }
    rm -rf "$PANEL_ROOT/cgi-bin"
    cp "$staging/index.html" "$PANEL_ROOT/index.html"
    cp -r "$staging/cgi-bin" "$PANEL_ROOT/cgi-bin"
    chmod 755 "$PANEL_ROOT/cgi-bin"/*
    rm -rf "$staging"

    if [ ! -x /etc/init.d/uhttpd ]; then
        warn "uhttpd не найден, панель обслуживать некому"
        return 1
    fi

    configure_panel_uhttpd

    # Порт проверяется запросом, а не объявляется. С несколькими попытками:
    # uhttpd после перезапуска поднимается не мгновенно, и первый же отказ
    # соединения выдавался за неработающую панель.
    answered=0
    for attempt in 1 2 3 4 5; do
        if command -v curl > /dev/null 2>&1 \
            && curl -fsS --max-time 3 -o /dev/null "http://127.0.0.1:$PANEL_PORT/"; then
            answered=1
            break
        fi
        sleep 1
    done

    if [ "$answered" -eq 1 ]; then
        note "панель отвечает на порту $PANEL_PORT"
    else
        warn "панель разложена, но порт $PANEL_PORT не ответил"
    fi

    return 0
}

# --- LuCI файлами ---------------------------------------------------------

XKOP_LUCI_VIEWS="api.js dashboard.js settings.js xkop.js"

install_luci_files() {
    ok=1

    mkdir -p /www/luci-static/resources/view/xkop
    for view in $XKOP_LUCI_VIEWS; do
        if fetch_repo_file "luci-app-xkop/htdocs/luci-static/resources/view/xkop/$view" "$WORK/$view"; then
            cp "$WORK/$view" "/www/luci-static/resources/view/xkop/$view"
        else
            warn "не скачался вид LuCI: $view"
            ok=0
        fi
    done

    mkdir -p /usr/share/luci/menu.d /usr/share/rpcd/acl.d
    for meta in luci/menu.d rpcd/acl.d; do
        if fetch_repo_file "luci-app-xkop/root/usr/share/$meta/luci-app-xkop.json" "$WORK/luci-meta.json"; then
            cp "$WORK/luci-meta.json" "/usr/share/$meta/luci-app-xkop.json"
        else
            warn "не скачался $meta/luci-app-xkop.json"
            ok=0
        fi
    done

    # Меню LuCI и права rpcd читаются один раз и кэшируются. Без сброса кэша
    # вкладка не появится до перезагрузки, и установка будет выглядеть
    # неудавшейся при полностью разложенных файлах.
    rm -f /tmp/luci-indexcache* 2> /dev/null
    rm -rf /tmp/luci-modulecache 2> /dev/null
    /etc/init.d/rpcd restart > /dev/null 2>&1

    [ "$ok" -eq 1 ]
}

# --- проверка системы -----------------------------------------------------

check_system() {
    model=$(cat /tmp/sysinfo/model 2> /dev/null)
    [ -n "$model" ] && note "роутер: $model"

    version=$(sed -n "s/^DISTRIB_RELEASE='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" /etc/openwrt_release 2> /dev/null | head -n 1)
    [ -n "$version" ] && note "OpenWrt $version"

    nslookup google.com > /dev/null 2>&1 || die "DNS не работает, ставить нечем"
}

pkg_format() {
    [ "$PKG_IS_APK" -eq 1 ] && echo apk || echo ipk
}

router_arch() {
    arch=""
    [ -r /etc/os-release ] && arch=$(. /etc/os-release 2> /dev/null && echo "${OPENWRT_ARCH:-}")
    [ -n "$arch" ] || arch=$(uname -m 2> /dev/null)
    echo "$arch"
}

asset_url() {
    jq -r --arg p "$1" --arg s "$2" \
        '[.assets[]? | select((.name | startswith($p)) and (.name | endswith($s)))]
         | first | .browser_download_url // empty' \
        "$WORK/release.json" 2> /dev/null
}

# --- начало работы --------------------------------------------------------

[ "$PKG_IS_APK" -eq 1 ] || command -v opkg > /dev/null 2>&1 || die "ни apk, ни opkg не найдены"

say "система"
check_system
fix_github_dns
sync_time

say "место"
# Место у пакетного менеджера должно быть в RAM: индекс и кэш архивов — ровно
# та временная запись, которая первой отказывает на почти полной флэш-памяти.
export TMPDIR=/tmp
reclaim_flash_space
free_kb=$(overlay_free_kb)
[ -n "$free_kb" ] && note "свободно на /overlay: ${free_kb} КБ"

# --- podkop, если он тут стоит --------------------------------------------

# Заменить podkop, не заставляя убирать его руками.
#
# Это не только удобство: пакет xkop объявляет конфликт с podkop, и на роутере
# с ним установка просто откажет. Но снять пакеты мало — podkop правит чужое
# состояние, и брошенное на полпути оно оставляет роутер без имён:
#
#   - dnsmasq смотрит на 127.0.0.42, а прежние резолверы спрятаны под ключами
#     podkop_*. Снять пакет, не вернув их, значит оставить роутер без DNS;
#   - таблица nft, правило и таблица маршрутизации, задачи в cron;
#   - строка "105 podkop" в /etc/iproute2/rt_tables;
#   - sing-box, который без podkop никому не нужен и занимает флэш.
#
# Поэтому порядок такой: сначала его собственный stop — он и есть штатный
# разбор, — потом возврат dnsmasq, и только затем удаление пакетов. Если
# удаление упрётся в место или права, роутер всё равно останется с именами.
podkop_present() {
    [ -x /usr/bin/podkop ] && return 0
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk list --installed 2> /dev/null | grep -q '^podkop-'
    else
        opkg list-installed 2> /dev/null | grep -q '^podkop '
    fi
}

# Что стоит прямо сейчас. Без этого установщик молча делал вид, что ставит
# начисто, и человек не понимал, обновление у него или переустановка того же.
installed_version() {
    # awk, а не sed: в этом окружении обратные слэши в генерируемом тексте
    # съедаются, и «слэш-единица» превращается в управляющий байт. Выражение
    # при этом выглядит целым, а подстановка молча ломается — проект
    # предупреждает об этом отдельным разделом, и здесь это уже случилось.
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk list --installed 2> /dev/null | awk '
            /^xkop-[0-9]/ { v = $1; sub("^xkop-", "", v); sub("-r[0-9]+$", "", v); print v; exit }'
    else
        opkg list-installed 2> /dev/null | awk '
            $1 == "xkop" { v = $3; sub("-r[0-9]+$", "", v); print v; exit }'
    fi
}

pkg_drop() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk del "$1" > /dev/null 2>&1
    else
        opkg remove --force-depends "$1" > /dev/null 2>&1
    fi
}

# Версия установленного движка.
#
# Сначала у менеджера, потом у самого бинарника. Второе обязательно: движок
# мог быть положен файлом с ветки, когда пакет не встал, — тогда менеджер
# о нём не знает вовсе, версия пустая, и сверка молча решает «не установлен».
# Итог: тридцать четыре мегабайта качаются в память при каждом запуске
# на роутере, где нужная версия уже лежит и работает.
#
# У пакета версия вида "26.7.28-r1", у бинарника "26.7.28" — сравнивается
# то, что от движка, без нашего номера сборки.
engine_pkg_version() {
    version=""

    if [ "$PKG_IS_APK" -eq 1 ]; then
        version=$(apk list --installed 2> /dev/null \
            | awk '/^xray-xkop-/ {print substr($1, 11); exit}')
    else
        version=$(opkg list-installed 2> /dev/null \
            | awk '$1 == "xray-xkop" {print $3; exit}')
    fi

    # Версия самого бинарника здесь НЕ годится, и это не мелочь.
    #
    # Движок, положенный файлом с ветки, менеджеру неизвестен: его нет
    # ни в списке пакетов, ни в админке, ни в обновлении. Задача установщика
    # — как раз поставить пакет на его место. Считать «версия совпала, качать
    # не буду» значит навсегда оставить роутер с движком-файлом, о котором
    # менеджер не знает. Поэтому пропуск только когда стоит именно ПАКЕТ.
    printf '%s' "$version"
}

# Версии сравниваются без номера сборки: "26.7.28-r1" и "26.7.28" — про один
# и тот же движок.
engine_version_core() {
    printf '%s' "${1%%-r[0-9]*}"
}

# Версия из имени файла в релизе: xray-xkop-26.7.28-r1-<арх>.<формат>.
engine_url_version() {
    name="${1##*/}"
    name="${name#xray-xkop-}"
    name="${name%-$ARCH.$FORMAT}"
    printf '%s' "$name"
}

# Установленные пакеты, чьё имя начинается с этого. Нужно там, где имя пакета
# зависит от того, кто его собирал: sing-box может называться sing-box,
# sing-box-extended и как угодно ещё.
# Имя пакета берётся у менеджера целиком, а не выкусывается из строки
# с версией. Версии бывают такие, что разобрать их выражением нельзя:
# "sing-box-extended-1.13.18-extended-2.6.4-r1" — слово "extended" в имени
# и оно же в версии. Любая попытка отрезать версию по первой цифре даёт
# "sing-box-extended-1.13.18-extended", а apk del на такое имя молча
# не делает ничего — ровно так пакет и остался на живом роутере, заняв
# место, которого потом не хватило движку.
pkg_installed_like() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        # apk info печатает только имена, по одному в строке.
        apk info 2> /dev/null
    else
        opkg list-installed 2> /dev/null | awk '{print $1}'
    fi | grep "^$1" | sort -u
}

# Возврат резолверов, спрятанных podkop под свои ключи. Делается до удаления
# пакетов и независимо от того, чем закончится удаление.
podkop_dnsmasq_restore() {
    local value

    command -v uci > /dev/null 2>&1 || return 0
    [ -n "$(uci -q get "dhcp.@dnsmasq[0].podkop_server")" ] || return 0

    uci -q delete "dhcp.@dnsmasq[0].server"
    for value in $(uci -q get "dhcp.@dnsmasq[0].podkop_server"); do
        uci -q add_list "dhcp.@dnsmasq[0].server=$value"
    done
    uci -q delete "dhcp.@dnsmasq[0].podkop_server"

    for value in noresolv cachesize; do
        saved=$(uci -q get "dhcp.@dnsmasq[0].podkop_$value")
        if [ -n "$saved" ]; then
            uci -q set "dhcp.@dnsmasq[0].$value=$saved"
            uci -q delete "dhcp.@dnsmasq[0].podkop_$value"
        else
            uci -q delete "dhcp.@dnsmasq[0].$value"
        fi
    done

    uci commit dhcp
    /etc/init.d/dnsmasq restart > /dev/null 2>&1
    note "прежние резолверы возвращены на место"
}

podkop_remove() {
    local pkg

    say "podkop"
    note "найден podkop, убираю"

    [ -x /etc/init.d/podkop ] && /etc/init.d/podkop stop > /dev/null 2>&1
    [ -x /usr/bin/podkop ] && /usr/bin/podkop stop > /dev/null 2>&1
    [ -x /etc/init.d/podkop ] && /etc/init.d/podkop disable > /dev/null 2>&1

    podkop_dnsmasq_restore

    for pkg in luci-i18n-podkop-ru luci-app-podkop podkop; do
        pkg_drop "$pkg"
    done

    # sing-box уходит следом: он был движком podkop и без него не нужен,
    # а места занимает больше самого podkop. Настройки движка остаются.
    #
    # Имя пакета не одно. podkop-forge ставит сборку с XHTTP, и называется она
    # sing-box-extended — «apk del sing-box» на неё не действует вовсе, пакет
    # остаётся на флэш и занимает десятки мегабайт. На живом роутере из-за
    # этого не хватило места движку. Поэтому снимается всё семейство, а какие
    # имена в нём есть — спрашивается у менеджера, а не угадывается.
    if [ -x /etc/init.d/sing-box ]; then
        /etc/init.d/sing-box stop > /dev/null 2>&1
        /etc/init.d/sing-box disable > /dev/null 2>&1
    fi

    for pkg in $(pkg_installed_like 'sing-box'); do
        pkg_drop "$pkg"
    done

    # Хвосты, до которых stop мог не добраться: если служба уже была сломана,
    # разбирать было некому.
    nft delete table inet PodkopTable > /dev/null 2>&1
    while ip rule list 2> /dev/null | grep -q 'lookup podkop'; do
        ip -4 rule del table podkop 2> /dev/null || break
    done
    ip route flush table podkop > /dev/null 2>&1
    sed -i '/105 podkop/d' /etc/iproute2/rt_tables 2> /dev/null

    if command -v crontab > /dev/null 2>&1; then
        crontab -l 2> /dev/null | grep -v '/usr/bin/podkop' | crontab - 2> /dev/null
        /etc/init.d/cron reload > /dev/null 2>&1
    fi

    # /etc/config/podkop остаётся намеренно: это настройки человека, и если он
    # решит вернуться, переписывать их заново незачем.
    if podkop_present; then
        warn "podkop убрать до конца не вышло, установка может упереться в конфликт"
    else
        note "podkop убран, /etc/config/podkop оставлен"
    fi
}

if podkop_present; then
    if [ "${XKOP_KEEP_PODKOP:-0}" = "1" ]; then
        warn "podkop оставлен по XKOP_KEEP_PODKOP — пакет xkop с ним конфликтует"
    else
        podkop_remove
    fi
fi

say "зависимости"
note "менеджер: $(pkg_format)"

# Черновики менеджера — в память.
#
# На большинстве сборок /var и так лежит в tmpfs, но не на всех, а индекс
# и скачанный архив, записанные на overlay, — ровно та временная запись,
# которая первой упирается в заполненную флэш. Перенято у podkop.
export TMPDIR=/tmp

pkg_world_repair
pkg_list_update || warn "индекс не обновился, ставлю на том, что есть"
for p in curl jq gzip coreutils-base64 unzip nftables kmod-nft-tproxy; do
    pkg_add "$p" || warn "не поставился: $p"
done

command -v jq > /dev/null 2>&1 || die "без jq команды xkop работать не будут"

rm -rf "$WORK"
mkdir -p "$WORK/lib"

FORMAT=$(pkg_format)
ARCH=$(router_arch)
note "архитектура: $ARCH, пакеты $FORMAT"

# --- пакетами, если есть релиз --------------------------------------------

# Работала ли служба до нашего вмешательства.
#
# prerm пакета останавливает её, а обратно не поднимает никто: обновление
# по скрипту оставляло роутер со свежими файлами и остановленным движком,
# и выглядело это как «поставил и всё сломалось». Возвращаем как было.
WAS_RUNNING=0
if [ -x /usr/bin/xkop ]     && [ "$(/usr/bin/xkop get_status 2> /dev/null | jq -r '.engine.running // false' 2> /dev/null)" = "true" ]; then
    WAS_RUNNING=1
fi

INSTALLED_FROM=""
SHA="$XKOP_REF"

if [ "${XKOP_FROM_BRANCH:-0}" != "1" ]; then
    say "релиз"
    if download "https://api.github.com/repos/$XKOP_REPO/releases/latest" "$WORK/release.json" \
        && [ -s "$WORK/release.json" ]; then

        VERSION=$(jq -r '.tag_name // empty' "$WORK/release.json" 2> /dev/null | sed 's/^v//')
        XKOP_URL=$(asset_url "xkop-" ".$FORMAT")
        LUCI_URL=$(asset_url "luci-app-xkop-" ".$FORMAT")
        ENGINE_URL=$(asset_url "xray-xkop-" "-$ARCH.$FORMAT")

        if [ -n "$XKOP_URL" ]; then
            HAVE=$(installed_version)
            if [ -z "$HAVE" ]; then
                note "ставлю $VERSION"
            elif [ "$HAVE" = "$VERSION" ]; then
                note "уже стоит $VERSION, переустанавливаю её же"
            else
                note "обновляю $HAVE -> $VERSION"
            fi

            file_unowned /usr/bin/xkop && branch_install_remove

            # Всё качается в RAM целиком и только потом ставится: отказ
            # на середине загрузки не должен оставлять роутер с половиной.
            # Движок весит тридцать с лишним мегабайт и качается в память.
            # Тянуть его при каждом запуске установщика, когда стоит ровно
            # та же версия, — лишние тридцать мегабайт в оперативной памяти
            # роутера, у которого её и так немного, и лишняя переустановка
            # на ровном месте. Версия в имени файла релиза и версия, которую
            # называет менеджер, — одна и та же строка вида "26.7.28-r1".
            ENGINE_HAVE=$(engine_version_core "$(engine_pkg_version)")
            ENGINE_WANT=$(engine_version_core "$(engine_url_version "$ENGINE_URL")")
            if [ -n "$ENGINE_HAVE" ] && [ "$ENGINE_HAVE" = "$ENGINE_WANT" ]; then
                note "движок $ENGINE_HAVE уже стоит, не качаю"
                ENGINE_URL=""
            fi

            if [ -n "$ENGINE_URL" ] && [ "${XKOP_NO_ENGINE:-0}" != "1" ]; then
                if download "$ENGINE_URL" "$WORK/engine.$FORMAT"; then
                    # Движок, положенный мимо менеджера, мешает пакету встать,
                    # но убирать его насовсем до установки нельзя: отказ пакета
                    # оставит роутер вовсе без движка. Поэтому он отходит
                    # в RAM и возвращается, если пакет не встал.
                    saved_engine=""
                    if file_unowned /usr/bin/xray; then
                        note "убираю движок, положенный мимо менеджера"
                        saved_engine="/tmp/xkop-xray.$$"
                        cp /usr/bin/xray "$saved_engine" && rm -f /usr/bin/xray
                    fi

                    if pkg_install_file "$WORK/engine.$FORMAT"; then
                        note "движок установлен пакетом"
                        rm -f "$saved_engine"
                    else
                        warn "движок пакетом не встал"
                        if [ -n "$saved_engine" ] && [ -s "$saved_engine" ] \
                            && [ ! -e /usr/bin/xray ]; then
                            cp "$saved_engine" /usr/bin/xray
                            chmod +x /usr/bin/xray
                            note "прежний движок возвращён на место"
                        fi
                        rm -f "$saved_engine"
                    fi
                fi
            elif [ "${XKOP_NO_ENGINE:-0}" != "1" ]; then
                warn "пакета движка под $ARCH в релизе нет"
            fi

            if download "$XKOP_URL" "$WORK/xkop.$FORMAT" && pkg_install_file "$WORK/xkop.$FORMAT"; then
                INSTALLED_FROM="release"
                note "xkop установлен пакетом"

                if [ -n "$LUCI_URL" ] && download "$LUCI_URL" "$WORK/luci.$FORMAT"; then
                    if pkg_install_file "$WORK/luci.$FORMAT"; then
                        note "LuCI установлен пакетом"
                        rm -f /tmp/luci-indexcache* 2> /dev/null
                        rm -rf /tmp/luci-modulecache 2> /dev/null
                        /etc/init.d/rpcd restart > /dev/null 2>&1
                    else
                        warn "LuCI пакетом не встал"
                    fi
                fi
            else
                warn "пакет xkop не встал, перехожу на файлы с ветки"
            fi
        else
            note "в релизе нет пакета под $FORMAT, беру файлы с ветки"
        fi
    else
        note "релизов ещё нет, беру файлы с ветки"
    fi
fi

# --- файлами с ветки, если пакетами не вышло ------------------------------

# Ветка разрешается в хэш один раз, и дальше всё тянется по хэшу.
# raw.githubusercontent отдаёт ветку из кэша и параметры запроса игнорирует —
# «?nocache=» ничего не менял, и устаревшая панель была неотличима от свежей.
say "источник"
download "https://api.github.com/repos/$XKOP_REPO/commits/$XKOP_REF" "$WORK/head.json" 2> /dev/null || true
if [ -s "$WORK/head.json" ]; then
    resolved=$(jq -r '.sha // empty' "$WORK/head.json" 2> /dev/null || true)
    [ -n "$resolved" ] && SHA="$resolved"
fi
note "$XKOP_REPO @ $(echo "$SHA" | cut -c1-7)"

if [ -z "$INSTALLED_FROM" ]; then
    say "файлы xkop"
    fetch_repo_file "xkop/files/usr/bin/xkop" "$WORK/xkop" || die "не удалось скачать xkop"

    # Список полный и обязательный: /usr/bin/xkop подключает библиотеки все,
    # и недостающая означает не «без одной возможности», а команду, которая
    # не запускается вовсе. Полнота списка проверяется в tests/installer.test.sh.
    XKOP_LIBS="constants.sh logging.sh lock.sh version.sh stats.sh stats.jq
subscription.sh subscription.jq config.sh config.jq lists.sh userlists.sh
nft.sh dnsmasq.sh canary.sh nodes.sh diagnostics.sh explain.sh update.sh
service.sh migrate.sh"

    for lib in $XKOP_LIBS; do
        fetch_repo_file "xkop/files/usr/lib/xkop/$lib" "$WORK/lib/$lib" \
            || die "не удалось скачать $lib"
    done

    fetch_repo_file "xkop/files/etc/init.d/xkop" "$WORK/init.d-xkop" \
        || die "не удалось скачать файл службы"

    mkdir -p "$XKOP_LIB_DIR"
    cp "$WORK"/lib/* "$XKOP_LIB_DIR/"
    cp "$WORK/xkop" /usr/bin/xkop
    cp "$WORK/init.d-xkop" /etc/init.d/xkop
    chmod +x /usr/bin/xkop /etc/init.d/xkop

    # Что обязано пережить обновление прошивки. В пакете этот файл кладёт
    # Makefile; при установке с ветки его нужно положить руками, иначе
    # состояние — кэш подписки, закреплённый узел, кэш списков — потеряется
    # при первом же sysupgrade, и роутер поднимется без узлов.
    if fetch_repo_file "xkop/files/lib/upgrade/keep.d/xkop" "$WORK/keep-xkop"; then
        mkdir -p /lib/upgrade/keep.d
        cp "$WORK/keep-xkop" /lib/upgrade/keep.d/xkop
        note "состояние помечено как переживающее обновление прошивки"
    else
        warn "не удалось положить /lib/upgrade/keep.d/xkop: состояние не переживёт sysupgrade"
    fi

    # У сборки версия подставляется из тега; установка с ветки ставит хэш,
    # чтобы роутер всегда мог сказать, что именно на нём работает.
    sed -i "s/__COMPILED_VERSION_VARIABLE__/$(echo "$SHA" | cut -c1-7)/" "$XKOP_LIB_DIR/constants.sh"

    if [ ! -f /etc/config/xkop ]; then
        fetch_repo_file "xkop/files/etc/config/xkop" "$WORK/config" && cp "$WORK/config" /etc/config/xkop
        note "/etc/config/xkop создан"
    else
        note "/etc/config/xkop оставлен как есть"
    fi

    # LuCI приезжает теми же файлами. Без неё роутер получает команды, но
    # не получает ни вкладки в «Сервисы», ни дашборда — установка выглядит
    # удавшейся, а смотреть не на что.
    say "LuCI"
    if install_luci_files; then
        note "LuCI разложена, вкладка «Сервисы → xkop»"
    else
        warn "LuCI разложена не полностью"
    fi

    if [ "${XKOP_NO_ENGINE:-0}" != "1" ] && ! command -v xray > /dev/null 2>&1; then
        say "движок"
        if fetch_repo_file "tools/install-xray-dev.sh" "$WORK/install-xray.sh"; then
            sh "$WORK/install-xray.sh" || warn "движок не поставился, xkop это переживёт"
        else
            warn "скрипт установки движка не скачался"
        fi
    fi

    INSTALLED_FROM="branch"
fi

# --- списки, вбитые руками в podkop ---------------------------------------
#
# У человека, жившего на podkop годами, в пользовательских списках лежат
# десятки доменов и подсетей — по одному, по мере того как что-то
# не открывалось. Заставлять вводить это заново значит потерять половину:
# часть он просто не вспомнит, и переход выйдет болезненным на ровном месте.
#
# Настройки podkop установщик оставляет на диске намеренно, поэтому перенести
# их можно уже после установки. Переносятся только пользовательские списки:
# категории, резолвер и подписка настраиваются заново и осознанно.
#
# Только в пустой профиль. Второй запуск установщика на настроенном роутере
# не имеет права трогать то, что человек уже поправил руками.

# Файл переноса берётся с ветки, а не из установленного пакета: при установке
# пакетом его в системе ещё нет, и условие «если файл на месте» тихо пропустило
# бы перенос ровно там, где он нужен, — на первой установке.
if [ -f /etc/config/podkop ]; then
    if [ -z "$(uci -q get xkop.blocked_ru.domain)" ] \
        && [ -z "$(uci -q get xkop.blocked_ru.subnet)" ]; then

        say "списки из podkop"

        moved=""
        if fetch_repo_file "xkop/files/usr/lib/xkop/migrate.sh" "$WORK/migrate.sh"; then
            moved=$(
                XKOP_CONFIG=xkop
                export XKOP_CONFIG
                # shellcheck source=/dev/null
                . "$WORK/migrate.sh"
                migrate_podkop_apply blocked_ru 2> /dev/null
            )
        else
            warn "не удалось скачать перенос списков, пропускаю"
        fi

        if [ -n "$moved" ] && [ "$moved" -gt 0 ] 2> /dev/null; then
            note "перенесено записей: $moved (свои домены и подсети)"
            note "категории, резолвер и подписку задайте сами — они не переносятся"
        else
            note "переносить нечего"
        fi
    fi
fi

# --- панель ---------------------------------------------------------------

# --- возвращаем службу как было -------------------------------------------

if [ "$WAS_RUNNING" -eq 1 ]; then
    say "служба"
    /etc/init.d/xkop restart > /dev/null 2>&1

    # Запущено и работает - разные утверждения, и различать их тут и есть
    # смысл проверки.
    started=0
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if [ "$(/usr/bin/xkop get_status 2> /dev/null | jq -r '.engine.answering // false' 2> /dev/null)" = "true" ]; then
            started=1
            break
        fi
        sleep 2
    done

    if [ "$started" -eq 1 ]; then
        note "служба работала до обновления и снова работает"
    else
        warn "служба не поднялась после обновления, смотри: logread -e xkop"
    fi
fi

# Панель — обычные файлы, а не пакет: её отдаёт отдельный экземпляр uhttpd,
# и обновляется она вместе со скриптами.
say "панель клиента"
install_client_panel || true

rm -rf "$WORK"

# --- проверка -------------------------------------------------------------

say "проверка"
/usr/bin/xkop version
echo
/usr/bin/xkop check_engine

echo
if [ -n "${HAVE:-}" ] && [ -n "${VERSION:-}" ] && [ "$HAVE" != "$VERSION" ]; then
    echo "== обновлено: $HAVE -> $VERSION ($INSTALLED_FROM)"
else
    echo "== установлено ($INSTALLED_FROM)"
fi
echo
echo "Дальше — ссылка подписки и запуск:"
echo
echo "  uci set xkop.main.url='https://ваша-ссылка' && uci commit xkop"
echo "  /etc/init.d/xkop enable && /etc/init.d/xkop start"
echo
echo "  xkop get_status"
echo
echo "Панель клиента:"
panel_address | while read -r url; do echo "  $url"; done
echo "  вход — пароль root от роутера"
echo
echo "Настройки целиком: LuCI, «Сервисы → xkop»"
echo "Обновление:        xkop update"
