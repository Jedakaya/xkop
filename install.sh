#!/bin/sh
# xkop installer. Runs ON THE ROUTER.
#
#   sh <(wget -O - https://raw.githubusercontent.com/Jedakaya/xkop/main/install.sh)
#
# While the repository is private that URL is not readable anonymously; pass a
# token instead, or use tools/setup-test-router.sh over ssh from the PC:
#
#   GITHUB_TOKEN=... sh install.sh
#
# What it does: packages xkop needs, the engine, the xkop files themselves.
# What it does not do yet: a service, a configuration, routing. There is one
# working command so far - stats - and this script exists to deliver it the
# same way the finished thing will be delivered.
#
# Settings, all optional:
#   XKOP_REPO=Jedakaya/xkop    XKOP_REF=main     GITHUB_TOKEN=...
#   XKOP_NO_ENGINE=1           не трогать движок
#   XRAY_TARGET=/tmp/xray      движок в RAM, ни байта на флэш

set -eu

XKOP_REPO=${XKOP_REPO:-Jedakaya/xkop}
XKOP_REF=${XKOP_REF:-main}
XKOP_LIB_DIR=/usr/lib/xkop
WORK=/tmp/xkop-install

say() { echo; echo "== $*"; }
die() { echo "!! $*" >&2; exit 1; }

# A fresh OpenWrt has no curl - only wget. Requiring curl before the package
# manager has run would fail on exactly the router this script exists for.
download() {
    # $1 - url, $2 - destination, $3 - optional auth header
    if command -v curl > /dev/null 2>&1; then
        if [ -n "${3:-}" ]; then
            curl -fsSL --max-time 120 -H "$3" -o "$2" "$1"
        else
            curl -fsSL --max-time 120 -o "$2" "$1"
        fi
    elif [ -z "${3:-}" ]; then
        wget -q -O "$2" "$1"
    else
        # Header authentication needs curl; busybox wget cannot do it.
        return 1
    fi
}

# Adapted from podkop, where it was bought with real failures: when the
# provider poisons DNS, GitHub stops resolving and every download dies with a
# reason that names the wrong problem. The musl resolver reads /etc/hosts
# before DNS, so static records help wget immediately.
fix_github_dns() {
    local marker="# xkop: github DNS fallback"
    local host broken=0

    grep -qF "$marker" /etc/hosts 2> /dev/null && return 0

    for host in raw.githubusercontent.com api.github.com github.com; do
        nslookup "$host" > /dev/null 2>&1 || broken=1
    done
    [ "$broken" -eq 0 ] && return 0

    echo "-- домены GitHub не резолвятся, добавляю записи в /etc/hosts"
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
    # $1 - path inside the repository, $2 - destination
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        download "https://api.github.com/repos/$XKOP_REPO/contents/$1?ref=$SHA" "$2" \
            "Authorization: Bearer $GITHUB_TOKEN" \
            && return 0
        # The API needs one more header to answer with the file itself.
        curl -fsSL --max-time 120 \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github.raw" \
            -o "$2" "https://api.github.com/repos/$XKOP_REPO/contents/$1?ref=$SHA"
    else
        download "https://raw.githubusercontent.com/$XKOP_REPO/$SHA/$1" "$2"
    fi
}

say "сеть"
fix_github_dns

say "зависимости"
packages="curl jq gzip coreutils-base64 unzip"
if command -v apk > /dev/null 2>&1; then
    echo "-- менеджер: apk"
    apk update > /dev/null 2>&1 || echo "!! индекс не обновился, ставлю на том, что есть"
    for p in $packages; do
        apk add --no-interactive "$p" > /dev/null 2>&1 || echo "!! не поставился: $p"
    done
elif command -v opkg > /dev/null 2>&1; then
    echo "-- менеджер: opkg"
    opkg update > /dev/null 2>&1 || echo "!! индекс не обновился, ставлю на том, что есть"
    for p in $packages; do
        opkg install "$p" > /dev/null 2>&1 || echo "!! не поставился: $p"
    done
else
    die "ни apk, ни opkg не найдены"
fi

command -v jq > /dev/null 2>&1 || die "без jq команды xkop работать не будут"

say "источник"
# The branch is resolved to a commit once, and everything is then fetched by
# that hash. raw.githubusercontent serves a branch from cache and ignores query
# parameters - an installer pulled by branch name arrives stale, which already
# happened twice on podkop. A hash is immutable and has no such problem.
rm -rf "$WORK"
mkdir -p "$WORK/lib"

SHA="$XKOP_REF"
if [ -n "${GITHUB_TOKEN:-}" ]; then
    download "https://api.github.com/repos/$XKOP_REPO/commits/$XKOP_REF" "$WORK/head.json" \
        "Authorization: Bearer $GITHUB_TOKEN" 2> /dev/null || true
else
    download "https://api.github.com/repos/$XKOP_REPO/commits/$XKOP_REF" "$WORK/head.json" 2> /dev/null || true
fi

if [ -s "$WORK/head.json" ]; then
    resolved=$(jq -r '.sha // empty' "$WORK/head.json" 2> /dev/null || true)
    [ -n "$resolved" ] && SHA="$resolved"
fi

if [ "$SHA" = "$XKOP_REF" ]; then
    echo "-- хэш коммита получить не удалось, беру по имени ветки"
else
    echo "-- $XKOP_REPO @ $(echo "$SHA" | cut -c1-7)"
fi

say "файлы xkop"
# Downloaded to /tmp first and only then installed: a half-finished download
# must not be able to leave the router with half a command.
fetch_repo_file "xkop/files/usr/bin/xkop" "$WORK/xkop" || die "не удалось скачать xkop"

# Список библиотек полный и обязательный: /usr/bin/xkop подключает их все,
# и недостающая означает не «без одной возможности», а команду, которая
# не запускается вовсе. Полнота списка проверяется в tests/installer.test.sh.
XKOP_LIBS="constants.sh logging.sh version.sh stats.sh stats.jq
subscription.sh subscription.jq config.sh config.jq lists.sh userlists.sh
nft.sh dnsmasq.sh canary.sh nodes.sh diagnostics.sh explain.sh service.sh"

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

# The package build substitutes the version; an install from the branch stamps
# the commit, so a router can always say what exactly is running on it.
sed -i "s/__COMPILED_VERSION_VARIABLE__/$(echo "$SHA" | cut -c1-7)/" "$XKOP_LIB_DIR/constants.sh"

if [ ! -f /etc/config/xkop ]; then
    fetch_repo_file "xkop/files/etc/config/xkop" "$WORK/config" && cp "$WORK/config" /etc/config/xkop
    echo "-- /etc/config/xkop создан"
else
    echo "-- /etc/config/xkop оставлен как есть"
fi

if [ "${XKOP_NO_ENGINE:-0}" != "1" ]; then
    say "движок"
    if fetch_repo_file "tools/install-xray-dev.sh" "$WORK/install-xray.sh"; then
        sh "$WORK/install-xray.sh" || echo "!! движок не поставился, xkop это переживёт"
    else
        echo "!! скрипт установки движка не скачался"
    fi
fi

say "панель клиента"
# Панель — обычные файлы, а не пакет: её отдаёт отдельный экземпляр uhttpd,
# и обновляется она вместе со скриптами, без тега и пересборки.
mkdir -p /www-xkop/cgi-bin
if fetch_repo_file "client-panel/index.html" "$WORK/index.html"; then
    cp "$WORK/index.html" /www-xkop/index.html
    for endpoint in _common auth status subscription-set subscription-update \
                    routes route-set node-select explain; do
        if fetch_repo_file "client-panel/cgi-bin/$endpoint" "$WORK/$endpoint"; then
            cp "$WORK/$endpoint" "/www-xkop/cgi-bin/$endpoint"
            chmod +x "/www-xkop/cgi-bin/$endpoint"
        else
            echo "!! не скачалась точка панели: $endpoint"
        fi
    done
    echo "-- панель в /www-xkop, порт 8090"
else
    echo "!! панель не скачалась, xkop это переживёт"
fi

say "конфигурация для проверки метрик"
if fetch_repo_file "tools/xray-stats-test.json" /tmp/xray-stats-test.json; then
    echo "-- /tmp/xray-stats-test.json"
else
    echo "!! не скачалась, проверку метрик придётся настраивать руками"
fi

rm -rf "$WORK"

say "проверка"
xkop version
echo
echo "-- xkop stats при остановленном движке:"
xkop stats | head -12

cat << 'EOF'

== дальше

  uci set xkop.main.url='https://ваша-ссылка' && uci commit xkop
  /etc/init.d/xkop enable && /etc/init.d/xkop start

  xkop get_status
  xkop stats

Панель клиента — http://адрес-роутера:8090, вход по паролю роутера.
Настройки целиком — в LuCI, раздел «Сервисы → xkop».

Проверить движок отдельно, без обвязки:

  xray run -c /tmp/xray-stats-test.json &
  xkop stats

Остальное — в docs/build.md.
EOF
