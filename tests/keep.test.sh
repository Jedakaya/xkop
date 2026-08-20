#!/bin/sh
# Удержание выбранного узла.
#
# Требование простое и высказано прямо: не прыгать при каждом чихе, переходить
# только когда узел умер или заметно деградировал. Ни leastPing, ни leastLoad
# такого не умеют — они считают заново и меняют выбор от шума измерения,
# — поэтому правило живёт у нас, и вот его проверки.

set -u

ROOT=${ROOT:-$(dirname "$0")/..}
JQ=${JQ:-jq}

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

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

XKOP_RUN_DIR="$work/run"
XKOP_BALANCER_TAG=pool
export XKOP_RUN_DIR XKOP_BALANCER_TAG
mkdir -p "$XKOP_RUN_DIR"

log_info() { :; }
log_warn() { :; }
log_error() { :; }

# Заглушки вместо роутера. Всё, что снаружи, задаётся переменными.
SELECTION='{"ok":true,"balancer":"pool","selection":"auto","selected":"DE","override":null}'
STATS='{"observatory":{"nodes":[]}}'
TOLERANCE=200
MAXDELAY=0
PINNED=""

# shellcheck source=/dev/null
. "$ROOT/xkop/files/usr/lib/xkop/nodes.sh"

# Заглушки ставятся ПОСЛЕ подключения: определённые до, они были бы перекрыты
# настоящими из самого модуля, и проверка молча ушла бы разговаривать
# с несуществующим движком.
nodes_selection_json() { printf '%s' "$SELECTION"; }
cmd_stats() { printf '%s' "$STATS"; }
config_uci_get() {
    case "$2" in
        switch_tolerance_ms) printf '%s' "$TOLERANCE" ;;
        max_delay_ms) printf '%s' "$MAXDELAY" ;;
    esac
}
nodes_api() {
    # bo -b pool <tag>  — закрепление
    PINNED="$4"
    printf '%s' "$PINNED" > "$work/pinned"
    return 0
}


pinned() { cat "$work/pinned" 2> /dev/null; }
reset() { rm -f "$work/pinned" "$(nodes_autopin_marker)"; }

# --- держимся, пока разница в пределах допуска ----------------------------

reset
STATS='{"observatory":{"nodes":[
    {"tag":"DE","state":"alive","delay_ms":380},
    {"tag":"FI","state":"alive","delay_ms":330}]}}'
out=$(nodes_keep)
check "выигрыш меньше допуска — держимся" "kept" "$(printf '%s' "$out" | "$JQ" -r '.result')"
check "держимся именно текущего" "DE" "$(printf '%s' "$out" | "$JQ" -r '.selected')"
check "и закрепляем его, чтобы не выбирался заново" "DE" "$(pinned)"

# --- переходим, когда выигрыш больше допуска ------------------------------

reset
STATS='{"observatory":{"nodes":[
    {"tag":"DE","state":"alive","delay_ms":900},
    {"tag":"FI","state":"alive","delay_ms":330}]}}'
out=$(nodes_keep)
check "заметный выигрыш — переходим" "switched" "$(printf '%s' "$out" | "$JQ" -r '.result')"
check "перешли на лучший" "FI" "$(printf '%s' "$out" | "$JQ" -r '.selected')"
check "и сказано, откуда" "DE" "$(printf '%s' "$out" | "$JQ" -r '.previous')"
check "и сказано, почему" "yes" \
    "$(printf '%s' "$out" | "$JQ" -r '.reason' | grep -q 'проигрывает лучшему' && echo yes || echo no)"

# --- умерший узел меняем независимо от допуска ----------------------------

reset
STATS='{"observatory":{"nodes":[
    {"tag":"DE","state":"dead","delay_ms":null},
    {"tag":"FI","state":"alive","delay_ms":330}]}}'
out=$(nodes_keep)
check "мёртвый текущий — переходим" "switched" "$(printf '%s' "$out" | "$JQ" -r '.result')"
check "причина названа честно" "yes" \
    "$(printf '%s' "$out" | "$JQ" -r '.reason' | grep -q 'не отвечает' && echo yes || echo no)"

# --- порог задержки, если он задан ----------------------------------------

reset
MAXDELAY=500
STATS='{"observatory":{"nodes":[
    {"tag":"DE","state":"alive","delay_ms":700},
    {"tag":"FI","state":"alive","delay_ms":650}]}}'
out=$(nodes_keep)
check "выше порога — уходим, хоть выигрыш и мал" "switched" \
    "$(printf '%s' "$out" | "$JQ" -r '.result')"
MAXDELAY=0

# --- закреплённое человеком не трогаем ------------------------------------

reset
SELECTION='{"ok":true,"balancer":"pool","selection":"manual","selected":"NL","override":"NL"}'
STATS='{"observatory":{"nodes":[
    {"tag":"NL","state":"alive","delay_ms":900},
    {"tag":"FI","state":"alive","delay_ms":100}]}}'
out=$(nodes_keep)
check "ручное закрепление сильнее автоматики" "manual" \
    "$(printf '%s' "$out" | "$JQ" -r '.result')"
check "и ничего не переключено" "" "$(pinned)"

# --- своё же закрепление менять можно -------------------------------------

reset
printf 'NL' > "$(nodes_autopin_marker)"
out=$(nodes_keep)
check "своё закрепление автоматика вправе сменить" "switched" \
    "$(printf '%s' "$out" | "$JQ" -r '.result')"
check "перешли на лучший" "FI" "$(pinned)"

# --- без данных наблюдения ничего не решаем -------------------------------

reset
SELECTION='{"ok":true,"balancer":"pool","selection":"auto","selected":"DE","override":null}'
STATS='{"observatory":{"nodes":[]}}'
out=$(nodes_keep)
check "нет измерений — выбор не трогаем" "no_data" \
    "$(printf '%s' "$out" | "$JQ" -r '.result')"
check "и ничего не закреплено" "" "$(pinned)"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
