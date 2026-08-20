#!/bin/sh
# Кэш версии движка не имеет права пережить смену самого движка.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
failed=0; total=0
check() {
    total=$((total + 1))
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: ожидалось '$2', получено '$3'"; failed=$((failed + 1)); fi
}

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
XKOP_RUN_DIR="$work/run"; mkdir -p "$XKOP_RUN_DIR"
XKOP_STATE_DIR="$work/state"; mkdir -p "$XKOP_STATE_DIR"
XKOP_CRON_MARKER='# xkop'
export XKOP_STATE_DIR
XKOP_ENGINE_BIN="$work/xray"
export XKOP_RUN_DIR XKOP_ENGINE_BIN
PATH="$work:$PATH"; export PATH

log_info() { :; }; log_warn() { :; }; log_error() { :; }

# shellcheck source=/dev/null
. "$ROOT/xkop/files/usr/lib/xkop/service.sh"

make_engine() {
    printf '#!/bin/sh\necho "Xray %s (Xray, Penetrates Everything.)"\n' "$1" > "$work/xray"
    chmod +x "$work/xray"
}

make_engine 26.3.27
check "версия прочитана" "26.3.27" "$(engine_version_cached)"
check "и взята из кэша повторно" "26.3.27" "$(engine_version_cached)"

# Движок сменился: содержимое другое, размер другой.
make_engine 26.7.28xx
check "смена движка кэш не переживает" "26.7.28xx" "$(engine_version_cached)"

# Сборка без `date -r`: отметка обязана добираться иначе, а не совпадать всегда.
date() { command date "$@"; }
make_engine 26.3.27
engine_version_cached > /dev/null
date() { case "$1" in -r) return 1 ;; *) command date "$@" ;; esac; }
# Отметка складывается из времени и размера: подмена в ту же секунду временем
# не ловится, размером ловится. Настоящее обновление движка меняет и то и то.
make_engine 26.9.99-longer
check "без date -r версия всё равно свежая" "26.9.99-longer" "$(engine_version_cached)"

echo "$((total - failed))/$total"
[ "$failed" -eq 0 ]
