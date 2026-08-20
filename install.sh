#!/bin/sh
# Установка xkop. Запускается НА РОУТЕРЕ.
#
#   sh <(wget -O - https://raw.githubusercontent.com/Jedakaya/xkop/main/install.sh)
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

pkg_install_file() {
    file="$1"
    [ -s "$file" ] || return 1

    if ! pkg_install_would_succeed "$file"; then
        warn "$(basename "$file") не встанет: менеджер отказал на сухом прогоне"
        report_flash_usage
        return 2
    fi

    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add --allow-untrusted --upgrade "$file" > /dev/null 2>&1
    else
        opkg install "$file" > /dev/null 2>&1
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

say "зависимости"
note "менеджер: $(pkg_format)"
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
            note "версия $VERSION"

            file_unowned /usr/bin/xkop && branch_install_remove

            # Всё качается в RAM целиком и только потом ставится: отказ
            # на середине загрузки не должен оставлять роутер с половиной.
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
    XKOP_LIBS="constants.sh logging.sh version.sh stats.sh stats.jq
subscription.sh subscription.jq config.sh config.jq lists.sh userlists.sh
nft.sh dnsmasq.sh canary.sh nodes.sh diagnostics.sh explain.sh update.sh
service.sh"

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

# --- панель ---------------------------------------------------------------

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
echo "== установлено ($INSTALLED_FROM)"
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
