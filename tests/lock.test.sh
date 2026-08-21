#!/bin/sh
# Замок от одновременного запуска.
#
# По расписанию бегут три задачи и рядом с ними запуск службы. Все трогают
# одно и то же: canary пишет в uci и перезапускает службу, keep читает
# состояние движка и закрепляет узел, prepare пересобирает конфигурацию.
# Две задачи, сошедшиеся в одну секунду, дают состояние, которое потом
# не воспроизвести.

set -u

ROOT=${ROOT:-$(dirname "$0")/..}
LIB="$ROOT/xkop/files/usr/lib/xkop"

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
export XKOP_RUN_DIR

log_info() { :; }
log_warn() { :; }
log_error() { :; }

# shellcheck source=/dev/null
. "$LIB/lock.sh"

check "первый берёт замок" "0" "$(lock_acquire test > /dev/null 2>&1; echo $?)"
check "каталог появился" "yes" \
    "$([ -d "$(lock_dir test)" ] && echo yes || echo no)"

# Второй в том же процессе взять не может: pid живой.
check "второй не берёт" "1" "$(lock_acquire test > /dev/null 2>&1; echo $?)"

lock_release test
check "после снятия берётся снова" "0" "$(lock_acquire test > /dev/null 2>&1; echo $?)"
lock_release test

# --- брошенный замок --------------------------------------------------------
#
# Аварийно убитая задача не имеет права заблокировать роутер навсегда.
# Живость определяется по /proc, поэтому подставляется заведомо мёртвый номер.

mkdir -p "$(lock_dir stale)"
printf '999999' > "$(lock_dir stale)/pid"
check "брошенный замок снимается" "0" "$(lock_acquire stale > /dev/null 2>&1; echo $?)"
lock_release stale

# Замок без номера процесса — тоже брошенный: писать его не успели.
mkdir -p "$(lock_dir empty)"
check "замок без номера считается брошенным" "0" \
    "$(lock_acquire empty > /dev/null 2>&1; echo $?)"
lock_release empty

# --- запуск под замком ------------------------------------------------------

: > "$work/ran"
job() { printf 'x' >> "$work/ran"; return 7; }

check "код возврата задачи передаётся" "7" "$(lock_run test job; echo $?)"
check "задача выполнилась" "x" "$(cat "$work/ran")"
check "замок снят после выполнения" "no" \
    "$([ -d "$(lock_dir test)" ] && echo yes || echo no)"

# Занято — тихий пропуск, а не отказ: задача по расписанию, пропустившая цикл,
# это норма, а вторая копия рядом с первой — нет.
mkdir -p "$(lock_dir test)"
printf '%s' "$$" > "$(lock_dir test)/pid"
: > "$work/ran"
check "занятый замок даёт нулевой код" "0" "$(lock_run test job > /dev/null 2>&1; echo $?)"
check "и задача не выполняется" "" "$(cat "$work/ran")"
lock_release test

# --- работа, которую пропускать нельзя --------------------------------------
#
# Запуск службы — единственный путь, которым на роутере появляются правила,
# резолвер и расписание. Обёрнутый в обычный замок prepare молча пропустился
# на обновлении пакета: служба остановилась (правила сняты), запуск попал
# на идущую задачу по расписанию, применение пропустилось — и весь трафик
# пошёл напрямую. Такая работа ждёт ограниченно, а потом делает своё дело
# всё равно.

XKOP_LOCK_WAIT=2
export XKOP_LOCK_WAIT

mkdir -p "$(lock_dir busy)"
printf '%s' "$$" > "$(lock_dir busy)/pid"

: > "$work/ran"
check "занятый замок не отменяет обязательную работу" "7"     "$(lock_run_anyway busy job > /dev/null 2>&1; echo $?)"
check "и работа выполнилась" "x" "$(cat "$work/ran")"
check "чужой замок при этом не тронут" "yes"     "$([ -d "$(lock_dir busy)" ] && echo yes || echo no)"
lock_release busy

# Свободный замок — берётся, и снимается после.
: > "$work/ran"
check "на свободном замке код возврата свой" "7" "$(lock_run_anyway free job; echo $?)"
check "и замок снят" "no" "$([ -d "$(lock_dir free)" ] && echo yes || echo no)"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
