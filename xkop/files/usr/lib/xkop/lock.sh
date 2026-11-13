#!/bin/sh
# shellcheck shell=ash
# Замок от одновременного запуска.
#
# По расписанию бегут три задачи: keep каждые пять минут, canary каждые
# семнадцать, access_trim каждые десять. Рядом с ними — запуск службы, кнопки
# в панели и триггер на подъём интерфейса. Все они трогают одно и то же:
# canary при находке пишет в uci и перезапускает службу, keep в это же время
# читает состояние движка и закрепляет узел, prepare пересобирает конфигурацию.
#
# Пока это не выстрелило, но класс отказа известен: две задачи, сошедшиеся
# в одну секунду, дают состояние, которое потом не воспроизвести. Дешевле
# не допустить, чем ловить раз в месяц.
#
# Замок — каталог, а не файл: mkdir атомарен на любой файловой системе
# и не требует flock, которого в сборке busybox может не быть. Лежит в RAM,
# поэтому перезагрузка снимает его сама.
#
# Брошенный замок опознаётся по живости процесса: аварийно убитая задача
# не имеет права заблокировать роутер навсегда.

lock_dir() {
    printf '%s/lock-%s' "$XKOP_RUN_DIR" "${1:-work}"
}

# PID plus kernel start time rejects a recycled PID. Old pid-only locks stay
# compatible and are treated conservatively until their process exits.
lock_identity() {
    local stat
    [ -r "/proc/$1/stat" ] || return 1
    read -r stat < "/proc/$1/stat" || return 1
    printf '%s:%s' "$1" "$(printf '%s' "${stat##*) }" | awk '{print $20}')"
}

# Reaping ownership is an empty directory named by process identity. Dead
# entries can be removed by their unique name without unlinking a successor.
lock_reaping_acquire() {
    local dir="$1" identity="$2" entry token pid attempt=0
    token="${identity%:*}-${identity#*:}"
    while ! mkdir "$dir/reaping" 2>/dev/null; do
        [ "$attempt" = 0 ] || return 1
        attempt=1
        for entry in "$dir/reaping"/*; do
            [ -d "$entry" ] || continue
            token=${entry##*/}
            pid=${token%%-*}
            if [ "$(lock_identity "$pid")" = "$pid:${token#*-}" ]; then return 1; fi
            rmdir "$entry" 2>/dev/null || return 1
        done
        # An owner paused between the two mkdir calls will fail its second
        # mkdir and must abort; a populated guard cannot be removed here.
        rmdir "$dir/reaping" 2>/dev/null || return 1
    done
    token="${identity%:*}-${identity#*:}"
    mkdir "$dir/reaping/$token" 2>/dev/null || return 1
    for entry in "$dir/reaping"/*; do
        if [ "$entry" != "$dir/reaping/$token" ]; then
            rmdir "$dir/reaping/$token" 2>/dev/null
            return 1
        fi
    done
}

lock_reaping_release() {
    rmdir "$1/reaping/${2%:*}-${2#*:}" 2>/dev/null
    rmdir "$1/reaping" 2>/dev/null
}

lock_acquire() {
    local name="${1:-work}" dir pid owner="$$" identity saved
    dir=$(lock_dir "$name")
    if [ -r /proc/self/stat ]; then read -r owner _ < /proc/self/stat || owner="$$"; fi
    identity=$(lock_identity "$owner") || return 1
    mkdir -p "$XKOP_RUN_DIR" 2>/dev/null || return 1
    if ! mkdir "$dir" 2>/dev/null; then
        pid=$(cat "$dir/pid" 2>/dev/null)
        if [ -z "$pid" ]; then sleep 1; pid=$(cat "$dir/pid" 2>/dev/null); fi
        saved=$(cat "$dir/identity" 2>/dev/null)
        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
            [ -n "$saved" ] || return 1
            [ "$(lock_identity "$pid")" != "$saved" ] || return 1
        fi
        # Only one stale contender can dismantle this directory. Never rm -rf:
        # a concurrent mkdir after rmdir must not be removed by the loser.
        lock_reaping_acquire "$dir" "$identity" || return 1
        if [ "$(cat "$dir/pid" 2>/dev/null)" != "$pid" ] \
            || [ "$(cat "$dir/identity" 2>/dev/null)" != "$saved" ]; then
            lock_reaping_release "$dir" "$identity"
            return 1
        fi
        log_warn "снимаю брошенный замок $name"
        rm -f "$dir/pid" "$dir/identity"
        lock_reaping_release "$dir" "$identity"
        rmdir "$dir" 2>/dev/null || return 1
        mkdir "$dir" 2>/dev/null || return 1
    fi
    printf '%s' "$owner" > "$dir/pid" && printf '%s' "$identity" > "$dir/identity" || return 1
    return 0
}

lock_release() {
    local dir owner="$$" identity
    dir=$(lock_dir "${1:-work}")
    if [ -r /proc/self/stat ]; then read -r owner _ < /proc/self/stat || owner="$$"; fi
    identity=$(lock_identity "$owner") || return 1
    [ "$(cat "$dir/identity" 2>/dev/null)" = "$identity" ] || return 0
    [ "$(cat "$dir/pid" 2>/dev/null)" = "$owner" ] || return 0
    rm -f "$dir/pid" "$dir/identity"
    rmdir "$dir" 2>/dev/null
}

# Subshell scope preserves the caller's traps, including nested locks. Signals
# terminate the worker; EXIT is the only owner allowed to release its lock.
lock_run() (
    name="$1"
    shift
    if ! lock_acquire "$name"; then
        log_info "занято другой задачей ($name), пропускаю цикл"
        return 0
    fi
    trap 'lock_release "$name"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    "$@"
)

# Mandatory startup must never race another writer. A busy result is explicit;
# the startup check/recovery loop retries once the current owner finishes.
lock_run_anyway() (
    name="$1" waited=0 limit="${XKOP_LOCK_WAIT:-15}"
    shift
    while :; do
        if lock_acquire "$name"; then
            trap 'lock_release "$name"' EXIT
            trap 'exit 130' INT
            trap 'exit 143' TERM
            "$@"
            return $?
        fi
        [ "$waited" -lt "$limit" ] || break
        sleep 1
        waited=$((waited + 1))
    done
    log_warn "замок $name занят, подготовка отложена до фонового восстановления"
    return 75
)
