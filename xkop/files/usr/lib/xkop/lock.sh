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

# Publish a fully initialized, nonempty guard with one rename. An empty guard
# would let two contenders remove/recreate it before either records ownership.
# BusyBox mv -T rejects an existing nonempty destination directory; stale
# cleanup can only rmdir unique dead-owner entries and an empty guard.
lock_reaping_acquire() {
    local dir="$1" identity="$2" entry token pid attempt=0 prepared
    token="${identity%:*}-${identity#*:}"
    prepared=$(mktemp -d "$XKOP_RUN_DIR/reaping.XXXXXX") || return 1
    if ! mkdir "$prepared/$token"; then rmdir "$prepared"; return 1; fi
    while ! mv -T "$prepared" "$dir/reaping" 2>/dev/null; do
        if [ "$attempt" != 0 ]; then
            rmdir "$prepared/$token" "$prepared" 2>/dev/null
            return 1
        fi
        attempt=1
        for entry in "$dir/reaping"/*; do
            [ -d "$entry" ] || continue
            pid=${entry##*/}
            if [ "$(lock_identity "${pid%%-*}")" = "${pid%%-*}:${pid#*-}" ]; then
                rmdir "$prepared/$token" "$prepared" 2>/dev/null
                return 1
            fi
            # Another stale cleaner may have removed this exact dead entry.
            # Never remove a differently named successor or a populated guard.
            rmdir "$entry" 2>/dev/null || true
        done
        rmdir "$dir/reaping" 2>/dev/null || true
    done
    return 0
}

lock_reaping_release() {
    rmdir "$1/reaping/${2%:*}-${2#*:}" 2>/dev/null
    rmdir "$1/reaping" 2>/dev/null
}

lock_acquire() {
    local name="${1:-work}" dir pid owner="$$" identity saved prepared
    dir=$(lock_dir "$name")
    if [ -r /proc/self/stat ]; then read -r owner _ < /proc/self/stat || owner="$$"; fi
    identity=$(lock_identity "$owner") || return 1
    mkdir -p "$XKOP_RUN_DIR" 2>/dev/null || return 1
    # An observable fresh lock must already identify its owner. Publishing
    # an empty directory first allowed a paused claimant to overwrite a later
    # winner after that winner recovered the apparently abandoned directory.
    prepared=$(mktemp -d "$XKOP_RUN_DIR/lock-new.XXXXXX") || return 1
    if ! { printf '%s' "$owner" > "$prepared/pid" \
        && printf '%s' "$identity" > "$prepared/identity"; }; then
        rm -f "$prepared/pid" "$prepared/identity"
        rmdir "$prepared" 2>/dev/null
        return 1
    fi
    if mv -T "$prepared" "$dir" 2>/dev/null; then return 0; fi
    rm -f "$prepared/pid" "$prepared/identity"
    rmdir "$prepared" 2>/dev/null
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
    # Take over in place while holding the guard. Releasing it before
    # rmdir/mkdir let another reaper block removal and left every caller
    # without a lock. The new live owner must be visible before release.
    if ! { printf '%s' "$owner" > "$dir/pid" \
        && printf '%s' "$identity" > "$dir/identity"; }; then
        rm -f "$dir/pid" "$dir/identity"
        lock_reaping_release "$dir" "$identity"
        return 1
    fi
    lock_reaping_release "$dir" "$identity"
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
