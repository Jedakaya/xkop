#!/bin/sh
# Version comparison and the engine capability table.

set -u

ROOT=${ROOT:-$(dirname "$0")/..}

# shellcheck source=/dev/null
. "$ROOT/xkop/files/usr/lib/xkop/version.sh"

failed=0
total=0

check() {
    local label="$1" expected="$2" actual="$3"
    total=$((total + 1))
    if [ "$expected" = "$actual" ]; then
        echo "ok   $label"
    else
        echo "FAIL $label: ожидалось $expected, получено $actual"
        failed=$((failed + 1))
    fi
}

ge() {
    if version_ge "$1" "$2"; then echo yes; else echo no; fi
}

supports() {
    engine_supports "$1" "$2"
    echo $?
}

check "нормализация v-префикса" "26.1.23" "$(version_normalize 'v26.1.23')"
check "нормализация суффикса релиза" "26.1.23" "$(version_normalize '26.1.23-r2')"
check "нормализация суффикса сборки" "1.13.12" "$(version_normalize '1.13.12-extended-2.4.0')"
check "нормализация хвостовой точки" "26.1" "$(version_normalize '26.1.')"

check "равные версии" "yes" "$(ge '26.1.23' '26.1.23')"
check "равные с префиксом" "yes" "$(ge 'v26.1.23' '26.1.23')"
check "старшая по младшему разряду" "yes" "$(ge '26.1.24' '26.1.23')"
check "младшая по младшему разряду" "no" "$(ge '26.1.22' '26.1.23')"
check "старшая по среднему разряду" "yes" "$(ge '26.7.1' '26.1.23')"
check "младшая по старшему разряду" "no" "$(ge '25.9.99' '26.1.23')"
check "короткая версия против длинной" "no" "$(ge '26.1' '26.1.23')"
check "длинная версия против короткой" "yes" "$(ge '26.1.23' '26.1')"
check "разрядность без лексикографики" "yes" "$(ge '26.10.0' '26.9.0')"
check "ведущий ноль не восьмеричный" "yes" "$(ge '26.08.0' '26.8.0')"
check "четвёртый разряд учитывается" "yes" "$(ge '26.1.23.1' '26.1.23')"

check "hysteria2 на проверенной версии" "0" "$(supports hysteria2 '26.1.23')"
check "hysteria2 на свежей версии" "0" "$(supports hysteria2 'v26.7.28')"
check "hysteria2 на версии из фида" "1" "$(supports hysteria2 '25.1.30')"
check "неизвестная возможность" "2" "$(supports ech '26.7.28')"
check "версия неизвестна" "2" "$(supports hysteria2 '')"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
