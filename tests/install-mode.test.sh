#!/bin/sh
# A failed package transaction must not silently become an unmanaged install.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed -n '/^install_require_release()/,/^}/p' "$ROOT/install.sh" > "$work/functions"
. "$work/functions"
die() { echo "$*" >&2; exit 1; }
failed=0
check() {
    if [ "$2" = "$3" ]; then echo "ok   $1"; else
        echo "FAIL $1: expected '$2', got '$3'"; failed=$((failed + 1))
    fi
}
INSTALLED_FROM=''; XKOP_FROM_BRANCH=0
(install_require_release) 2> "$work/error"; rc=$?
check "ошибка пакета останавливает установку" 1 "$rc"
INSTALLED_FROM=release
(install_require_release); rc=$?
check "пакетный режим разрешён" 0 "$rc"
INSTALLED_FROM=''; XKOP_FROM_BRANCH=1
(install_require_release); rc=$?
check "явный режим разработки разрешён" 0 "$rc"
check "защита стоит до копирования с ветки" yes "$(awk '
    /^install_require_release$/ { gate=NR }
    /^# --- Files from a branch/ { files=NR }
    END { print ((gate > 0 && files > gate) ? "yes" : "no") }
' "$ROOT/install.sh")"
[ "$failed" -eq 0 ]
