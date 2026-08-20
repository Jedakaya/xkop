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
# Переменные, все необязательные:
#   XKOP_REPO=Jedakaya/xkop    XKOP_REF=main
#   XKOP_FROM_BRANCH=1         не смотреть релизы, ставить с ветки
#   XKOP_NO_ENGINE=1           не трогать движок
#   GITHUB_TOKEN=...           если репозиторий закрыт

set -eu

XKOP_REPO=${XKOP_REPO:-Jedakaya/xkop}
XKOP_REF=${XKOP_REF:-main}
XKOP_LIB_DIR=/usr/lib/xkop
PANEL_ROOT=/www-xkop
WORK=/tmp/xkop-install

say() { echo; echo "== $*"; }
note() { echo "-- $*"; }
warn() { echo "!! $*"; }
die() { echo "!! $*" >&2; exit 1; }

# На свежей OpenWrt curl нет, есть только wget. Требовать curl до того, как
# отработает пакетный менеджер, значит отказать ровно тому роутеру, ради
# которого этот скрипт и написан.
download() {
    if command -v curl > /dev/null 2>&1; then
        if [ -n "${3:-}" ]; then
            curl -fsSL --max-time 300 -H "$3" -o "$2" "$1"
        else
            curl -fsSL --max-time 300 -o "$2" "$1"
        fi
    elif [ -z "${3:-}" ]; then
        wget -q -O "$2" "$1"
    else
        return 1
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

    /etc/init.d/dnsmasq restart > /dev/null 2>&1 || true
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

pkg_format() {
    if command -v apk > /dev/null 2>&1; then echo apk; else echo ipk; fi
}

router_arch() {
    arch=""
    [ -r /etc/os-release ] && arch=$(. /etc/os-release 2> /dev/null && echo "${OPENWRT_ARCH:-}")
    [ -n "$arch" ] || arch=$(uname -m 2> /dev/null)
    echo "$arch"
}

# Место проверяется ПОСЛЕ загрузки и ДО установки, по реальному размеру файла.
# Фиксированный порог сам по себе отказывал роутерам, которым нужен был
# мегабайт.
install_package_file() {
    file="$1"
    [ -s "$file" ] || return 1

    size_kb=$(( ($(wc -c < "$file") + 1023) / 1024 ))
    free_kb=$(df -k /overlay 2> /dev/null | awk 'NR==2 {print $4}')
    [ -n "$free_kb" ] || free_kb=$(df -k / 2> /dev/null | awk 'NR==2 {print $4}')

    if [ -n "$free_kb" ] && [ "$free_kb" -lt "$size_kb" ]; then
        warn "не хватает места под $(basename "$file"): нужно ${size_kb} КБ, свободно ${free_kb} КБ"
        return 2
    fi

    if command -v apk > /dev/null 2>&1; then
        apk add --allow-untrusted --upgrade "$file" > /dev/null 2>&1
    else
        opkg install "$file" > /dev/null 2>&1
    fi
}

asset_url() {
    jq -r --arg p "$1" --arg s "$2" \
        '[.assets[]? | select((.name | startswith($p)) and (.name | endswith($s)))]
         | first | .browser_download_url // empty' \
        "$WORK/release.json" 2> /dev/null
}

# --- зависимости ----------------------------------------------------------

say "сеть"
fix_github_dns

say "зависимости"
packages="curl jq gzip coreutils-base64 unzip nftables kmod-nft-tproxy"
if command -v apk > /dev/null 2>&1; then
    note "менеджер: apk"
    apk update > /dev/null 2>&1 || warn "индекс не обновился, ставлю на том, что есть"
    for p in $packages; do
        apk add --no-interactive "$p" > /dev/null 2>&1 || warn "не поставился: $p"
    done
elif command -v opkg > /dev/null 2>&1; then
    note "менеджер: opkg"
    opkg update > /dev/null 2>&1 || warn "индекс не обновился, ставлю на том, что есть"
    for p in $packages; do
        opkg install "$p" > /dev/null 2>&1 || warn "не поставился: $p"
    done
else
    die "ни apk, ни opkg не найдены"
fi

command -v jq > /dev/null 2>&1 || die "без jq команды xkop работать не будут"

rm -rf "$WORK"
mkdir -p "$WORK/lib"

FORMAT=$(pkg_format)
ARCH=$(router_arch)
note "роутер: $ARCH, пакеты $FORMAT"

# --- пакетами, если есть релиз --------------------------------------------

INSTALLED_FROM=""

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

            # Всё качается в RAM целиком и только потом ставится: отказ
            # на середине загрузки не должен оставлять роутер с половиной.
            if [ -n "$ENGINE_URL" ] && [ "${XKOP_NO_ENGINE:-0}" != "1" ]; then
                if download "$ENGINE_URL" "$WORK/engine.$FORMAT"; then
                    install_package_file "$WORK/engine.$FORMAT" \
                        && note "движок установлен пакетом" \
                        || warn "движок пакетом не встал"
                fi
            elif [ "${XKOP_NO_ENGINE:-0}" != "1" ]; then
                warn "пакета движка под $ARCH в релизе нет"
            fi

            if download "$XKOP_URL" "$WORK/xkop.$FORMAT" && install_package_file "$WORK/xkop.$FORMAT"; then
                INSTALLED_FROM="release"
                note "xkop установлен пакетом"

                if [ -n "$LUCI_URL" ] && download "$LUCI_URL" "$WORK/luci.$FORMAT"; then
                    install_package_file "$WORK/luci.$FORMAT" \
                        && note "LuCI установлен пакетом" \
                        || warn "LuCI пакетом не встал"
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

if [ -z "$INSTALLED_FROM" ]; then
    say "источник"
    # Ветка разрешается в хэш один раз, и дальше всё тянется по хэшу.
    # raw.githubusercontent отдаёт ветку из кэша и параметры запроса
    # игнорирует — установщик, взятый по имени ветки, приезжает устаревшим,
    # на чём в podkop дважды обжигались.
    SHA="$XKOP_REF"
    download "https://api.github.com/repos/$XKOP_REPO/commits/$XKOP_REF" "$WORK/head.json" 2> /dev/null || true
    if [ -s "$WORK/head.json" ]; then
        resolved=$(jq -r '.sha // empty' "$WORK/head.json" 2> /dev/null || true)
        [ -n "$resolved" ] && SHA="$resolved"
    fi
    note "$XKOP_REPO @ $(echo "$SHA" | cut -c1-7)"

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
[ -n "${SHA:-}" ] || SHA="$XKOP_REF"
mkdir -p "$PANEL_ROOT/cgi-bin"
if fetch_repo_file "client-panel/index.html" "$WORK/index.html"; then
    cp "$WORK/index.html" "$PANEL_ROOT/index.html"
    for endpoint in _common auth status subscription-set subscription-update \
                    routes route-set node-select explain; do
        if fetch_repo_file "client-panel/cgi-bin/$endpoint" "$WORK/$endpoint"; then
            cp "$WORK/$endpoint" "$PANEL_ROOT/cgi-bin/$endpoint"
            chmod +x "$PANEL_ROOT/cgi-bin/$endpoint"
        else
            warn "не скачалась точка панели: $endpoint"
        fi
    done
    note "панель в $PANEL_ROOT, порт 8090"
else
    warn "панель не скачалась, xkop это переживёт"
fi

rm -rf "$WORK"

# --- проверка -------------------------------------------------------------

say "проверка"
/usr/bin/xkop version
echo
/usr/bin/xkop check_engine

cat << EOF

== установлено ($INSTALLED_FROM)

Дальше — ссылка подписки и запуск:

  uci set xkop.main.url='https://ваша-ссылка' && uci commit xkop
  /etc/init.d/xkop enable && /etc/init.d/xkop start

  xkop get_status

Панель клиента:  http://\$(адрес роутера):8090
Настройки целиком: LuCI, «Сервисы → xkop»
Обновление:      xkop update
EOF
