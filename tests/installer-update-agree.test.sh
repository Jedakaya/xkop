#!/bin/sh
# Установщик и обновление обязаны понимать роутер одинаково.
#
# Одни и те же вопросы — какой менеджер пакетов, какая архитектура, где взять
# файл релиза, какая версия движка стоит — решаются в двух местах: в install.sh
# и в update.sh. Свести их в один файл нельзя: установщик работает до того,
# как что-либо установлено, и опереться на библиотеку не может.
#
# Значит остаётся сверять поведение. Куплено сегодня: сверку версии движка
# я правил в двух местах и в одном сделал иначе, чем в другом, — расхождение
# заметил только потому, что смотрел на оба файла подряд.
#
# Сравниваются ответы, а не текст: реализации написаны по-разному намеренно
# (printf против echo, local против без), и требовать буквального совпадения
# значило бы запретить им отличаться там, где это неважно.

set -u

ROOT=${ROOT:-$(dirname "$0")/..}
INSTALL="$ROOT/install.sh"
UPDATE="$ROOT/xkop/files/usr/lib/xkop/update.sh"

failed=0
total=0

check() {
    local label="$1" expected="$2" actual="$3"
    total=$((total + 1))
    if [ "$expected" = "$actual" ]; then
        echo "ok   $label"
    else
        echo "FAIL $label: установщик '$expected', обновление '$actual'"
        failed=$((failed + 1))
    fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Тело функции вырезается из файла как есть и переименовывается: две функции
# с одним именем в одной оболочке не уживаются.
extract() {
    sed -n "/^$2()/,/^}/p" "$1" | sed "1s/^$2()/$3()/"
}

{
    extract "$INSTALL" pkg_format i_pkg_format
    extract "$INSTALL" router_arch i_router_arch
    extract "$INSTALL" asset_url i_asset_url
    extract "$INSTALL" engine_pkg_version i_engine_version
    extract "$UPDATE" update_pkg_format u_pkg_format
    extract "$UPDATE" update_router_arch u_router_arch
    extract "$UPDATE" update_asset_url u_asset_url
    extract "$UPDATE" update_engine_installed_version u_engine_version
} > "$work/both.sh"

# Окружение, от которого зависят обе стороны.
PKG_IS_APK=0
command -v apk > /dev/null 2>&1 && PKG_IS_APK=1
WORK="$work"
XKOP_RUN_DIR="$work"

cat > "$work/release.json" << 'EOF'
{"tag_name": "v0.2.8", "assets": [
    {"name": "xkop-0.2.8-r1.apk", "browser_download_url": "https://example.com/xkop.apk"},
    {"name": "xray-xkop-26.7.28-r1-aarch64_cortex-a53.apk", "browser_download_url": "https://example.com/engine.apk"},
    {"name": "xkop-0.2.8-r1.ipk", "browser_download_url": "https://example.com/xkop.ipk"}
]}
EOF

# shellcheck source=/dev/null
. "$work/both.sh"

check "менеджер пакетов" "$(i_pkg_format)" "$(u_pkg_format)"
check "архитектура роутера" "$(i_router_arch)" "$(u_router_arch)"
check "ссылка на пакет" "$(i_asset_url 'xkop-' '.apk')" "$(u_asset_url 'xkop-' '.apk')"
check "ссылка на движок" \
    "$(i_asset_url 'xray-xkop-' '-aarch64_cortex-a53.apk')" \
    "$(u_asset_url 'xray-xkop-' '-aarch64_cortex-a53.apk')"
check "несуществующий пакет — пусто у обоих" \
    "$(i_asset_url 'нет-такого-' '.apk')" "$(u_asset_url 'нет-такого-' '.apk')"

# Версия движка: обе стороны спрашивают менеджер, поэтому он подменяется.
apk() {
    [ "$1" = "list" ] || return 0
    printf 'xray-xkop-26.7.28-r1 aarch64_cortex-a53 {x} (MPL-2.0) [installed]\n'
    printf 'xkop-0.2.8-r1 aarch64_cortex-a53 {y} (MIT) [installed]\n'
}
opkg() {
    [ "$1" = "list-installed" ] || return 0
    printf 'xray-xkop - 26.7.28-r1\n'
}

check "версия движка" "$(i_engine_version)" "$(u_engine_version)"
check "и она не пустая" "26.7.28-r1" "$(i_engine_version)"

# Движка нет вовсе — обе стороны обязаны сказать «пусто», а не выдумать.
apk() {
    [ "$1" = "list" ] || return 0
    printf 'busybox-1.37.0-r1 aarch64_cortex-a53 {z} (GPL) [installed]\n'
}
opkg() { printf 'busybox - 1.37.0\n'; }

check "движка нет — пусто у обоих" "$(i_engine_version)" "$(u_engine_version)"
check "и это действительно пусто" "" "$(i_engine_version)"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
