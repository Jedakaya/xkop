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

lock_acquire() {
    local name="${1:-work}" dir pid
    dir=$(lock_dir "$name")

    mkdir -p "$XKOP_RUN_DIR" 2> /dev/null

    if mkdir "$dir" 2> /dev/null; then
        printf '%s' "$$" > "$dir/pid" 2> /dev/null
        return 0
    fi

    # Замок занят. Живым ли?
    pid=$(cat "$dir/pid" 2> /dev/null)
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
        return 1
    fi

    log_warn "снимаю брошенный замок $name"
    rm -rf "$dir" 2> /dev/null
    mkdir "$dir" 2> /dev/null || return 1
    printf '%s' "$$" > "$dir/pid" 2> /dev/null
    return 0
}

lock_release() {
    rm -rf "$(lock_dir "${1:-work}")" 2> /dev/null
}

# Выполнить под замком. Не досталось — тихо уйти: задача по расписанию,
# пропустившая один цикл, это норма, а вторая копия рядом с первой — нет.
#
# Замок снимается и при аварийном выходе: без этого один kill оставлял бы
# роутер без фоновых задач до перезагрузки.
lock_run() {
    local name="$1"
    shift

    if ! lock_acquire "$name"; then
        log_info "занято другой задачей ($name), пропускаю цикл"
        return 0
    fi

    trap 'lock_release "'"$name"'"' EXIT INT TERM
    "$@"
    lock_status=$?
    lock_release "$name"
    trap - EXIT INT TERM

    return $lock_status
}
