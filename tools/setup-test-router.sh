#!/bin/sh
# Sets up a test router from scratch. Runs ON THE PC, works over ssh.
#
# Everything the bench needs and nothing more: packages xkop depends on, the
# engine, the xkop files themselves and a metrics config to point it at. No
# package build is involved - for a shell change that would be minutes of
# waiting for a result a copy delivers in a second.
#
# Usage:
#   tools/setup-test-router.sh root@192.168.0.139
#   tools/setup-test-router.sh root@192.168.0.139 --no-engine
#
# Repeatable: run it again after any change, it overwrites what it owns and
# leaves /etc/config/xkop alone.

set -eu

ROOT=$(dirname "$0")/..
TARGET=${1:-${XKOP_ROUTER:-}}
MODE=${2:-}

if [ -z "$TARGET" ]; then
    echo "укажите роутер: tools/setup-test-router.sh root@192.168.0.139" >&2
    exit 2
fi

say() { echo; echo "== $*"; }

say "роутер"
ssh "$TARGET" '. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-OpenWrt}"; echo "архитектура: ${OPENWRT_ARCH:-$(uname -m)}"; echo "свободно на /: $(df -h / | awk "NR==2 {print \$4}")"'

say "зависимости"
# apk on OpenWrt 25 and newer, opkg on 23 and 24. The two branches are always
# written together: the opkg one is the one that stays undertested otherwise.
ssh "$TARGET" '
    set -e
    packages="curl jq gzip coreutils-base64 unzip"
    if command -v apk > /dev/null 2>&1; then
        echo "менеджер: apk"
        apk update
        for p in $packages; do apk add --no-interactive "$p" || echo "!! не поставился: $p"; done
    elif command -v opkg > /dev/null 2>&1; then
        echo "менеджер: opkg"
        opkg update
        for p in $packages; do opkg install "$p" || echo "!! не поставился: $p"; done
    else
        echo "!! ни apk, ни opkg не найдены"
        exit 1
    fi
'

if [ "$MODE" != "--no-engine" ]; then
    say "движок"
    scp -q "$ROOT/tools/install-xray-dev.sh" "$TARGET:/tmp/install-xray-dev.sh"
    ssh "$TARGET" 'sh /tmp/install-xray-dev.sh'
fi

say "xkop"
sh "$ROOT/tools/deploy-dev.sh" "$TARGET"

say "конфигурация для проверки метрик"
scp -q "$ROOT/tools/xray-stats-test.json" "$TARGET:/tmp/xray-stats-test.json"

# The engine is deliberately not started: a command that reports "движок не
# запущен" is a real check of the failure branch, and it should be seen once
# before anything is running.
say "проверка команды при остановленном движке"
ssh "$TARGET" 'xkop stats | head -20'

cat <<EOF

== дальше руками на роутере

  xray run -c /tmp/xray-stats-test.json &
  xkop stats

Ожидается ok=true, нулевое распределение и узел direct в состоянии pending -
проверок ещё не было. Через минуту он должен стать alive с задержкой.
Подробности и остальные проверки в docs/build.md.
EOF
