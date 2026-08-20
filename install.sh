#!/bin/sh
# xkop installer. Runs ON THE ROUTER.
#
#   wget -qO- https://raw.githubusercontent.com/Jedakaya/xkop/main/install.sh | sh
#
# While the repository is private that URL is not readable anonymously; pass a
# token instead, or use tools/setup-test-router.sh over ssh from the PC:
#
#   GITHUB_TOKEN=... sh install.sh
#
# What it does: packages xkop needs, the engine, the xkop files themselves.
# What it does not do yet: a service, a configuration, routing. There is one
# working command so far - stats - and this script exists to deliver it to a
# router the same way the finished thing will be delivered.
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

api() {
    # $1 - path under the repository, $2 - destination file
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsSL --max-time 60 \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github.raw" \
            -o "$2" "https://api.github.com/repos/$XKOP_REPO/contents/$1?ref=$SHA"
    else
        curl -fsSL --max-time 60 \
            -o "$2" "https://raw.githubusercontent.com/$XKOP_REPO/$SHA/$1"
    fi
}

command -v curl > /dev/null 2>&1 || die "нужен curl"

say "источник"
# The branch is resolved to a commit once, and everything is then fetched by
# that hash. raw.githubusercontent serves a branch from cache and ignores query
# parameters - an installer pulled by branch name arrives stale, which already
# happened twice on podkop. A hash is immutable and has no such problem.
if [ -n "${GITHUB_TOKEN:-}" ]; then
    SHA=$(curl -fsSL --max-time 30 -H "Authorization: Bearer $GITHUB_TOKEN" \
        "https://api.github.com/repos/$XKOP_REPO/commits/$XKOP_REF" 2> /dev/null \
        | sed -n 's/^  "sha": "\(.*\)",$/\1/p' | head -n 1)
else
    SHA=$(curl -fsSL --max-time 30 \
        "https://api.github.com/repos/$XKOP_REPO/commits/$XKOP_REF" 2> /dev/null \
        | sed -n 's/^  "sha": "\(.*\)",$/\1/p' | head -n 1)
fi

if [ -z "$SHA" ]; then
    echo "-- хэш коммита получить не удалось, беру по имени ветки"
    SHA="$XKOP_REF"
else
    echo "-- $XKOP_REPO @ $(echo "$SHA" | cut -c1-7)"
fi

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

rm -rf "$WORK"
mkdir -p "$WORK/lib"

say "файлы xkop"
# Downloaded to /tmp first and only then installed: a half-finished download
# must not be able to leave the router with half a command.
api "xkop/files/usr/bin/xkop" "$WORK/xkop" || die "не удалось скачать xkop"
for lib in constants.sh stats.sh stats.jq subscription.sh subscription.jq version.sh; do
    api "xkop/files/usr/lib/xkop/$lib" "$WORK/lib/$lib" || die "не удалось скачать $lib"
done

mkdir -p "$XKOP_LIB_DIR"
cp "$WORK"/lib/* "$XKOP_LIB_DIR/"
cp "$WORK/xkop" /usr/bin/xkop
chmod +x /usr/bin/xkop

# The package build substitutes the version; an install from the branch stamps
# the commit, so a router can always say what exactly is running on it.
sed -i "s/__COMPILED_VERSION_VARIABLE__/$(echo "$SHA" | cut -c1-7)/" "$XKOP_LIB_DIR/constants.sh"

if [ ! -f /etc/config/xkop ]; then
    api "xkop/files/etc/config/xkop" "$WORK/config" && cp "$WORK/config" /etc/config/xkop
    echo "-- /etc/config/xkop создан"
else
    echo "-- /etc/config/xkop оставлен как есть"
fi

if [ "${XKOP_NO_ENGINE:-0}" != "1" ]; then
    say "движок"
    if api "tools/install-xray-dev.sh" "$WORK/install-xray.sh"; then
        sh "$WORK/install-xray.sh" || echo "!! движок не поставился, xkop это переживёт"
    else
        echo "!! скрипт установки движка не скачался"
    fi
fi

say "конфигурация для проверки метрик"
api "tools/xray-stats-test.json" /tmp/xray-stats-test.json \
    && echo "-- /tmp/xray-stats-test.json" \
    || echo "!! не скачалась, проверку метрик придётся настраивать руками"

rm -rf "$WORK"

say "проверка"
xkop version
echo
echo "-- xkop stats при остановленном движке:"
xkop stats | head -12

cat <<'EOF'

== дальше

  xray run -c /tmp/xray-stats-test.json &
  xkop stats

Ожидается ok=true, нулевое распределение и узел direct в состоянии pending.
Через минуту он должен стать alive с задержкой. Остальное — в docs/build.md.
EOF
