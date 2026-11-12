#!/bin/sh
# shellcheck shell=ash
# dnsmasq: pointing the router's resolver at the engine, and putting it back.
#
# Touched only when the DNS mode asks for it. In the default mode xkop does not
# go near dnsmasq at all - domains are recognised by the name inside the
# connection, and the resolver keeps answering exactly as it did before.
#
# What is replaced is written down before it is replaced, under our own option
# names, so that restoring is reading a value rather than guessing a default.
# A router left with someone else's idea of "the default DNS" is a router whose
# owner has to work out what it used to be.

XKOP_DNSMASQ_INIT=${XKOP_DNSMASQ_INIT:-/etc/init.d/dnsmasq}

# Значение, которого не было. Пустое сохранить нельзя — uci его не хранит,
# а отсутствие резервной копии неотличимо от «копию не делали».
XKOP_DNSMASQ_UNSET='-'

# Keep command output and preserve its exit status on both BusyBox variants.
dnsmasq_run_bounded() {
    local secs="$1" pid watcher rc
    shift
    if timeout -s KILL 1 true > /dev/null 2>&1; then
        timeout -s KILL "$secs" "$@"
        return $?
    fi
    if timeout -s KILL -t 1 true > /dev/null 2>&1; then
        timeout -s KILL -t "$secs" "$@"
        return $?
    fi
    "$@" &
    pid=$!
    (sleep "$secs"; kill -9 "$pid" 2>/dev/null) &
    watcher=$!
    wait "$pid"; rc=$?
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    return "$rc"
}

dnsmasq_verify() {
    # localhost is supplied by /etc/hosts: WAN availability is irrelevant.
    dnsmasq_run_bounded 3 "$XKOP_DNSMASQ_INIT" status > /dev/null 2>&1 \
        && dnsmasq_run_bounded 3 nslookup localhost 127.0.0.1 > /dev/null 2>&1
}

dnsmasq_restart_checked() {
    local output attempt=0 result logdir="${XKOP_RUN_DIR:-/tmp}" logfile
    mkdir -p "$logdir" || return 1
    logfile="$logdir/dnsmasq-restart.$$.log"
    (umask 077; : > "$logfile") || return 1
    dnsmasq_run_bounded 15 "$XKOP_DNSMASQ_INIT" restart > "$logfile" 2>&1
    result=$?
    output=$(tail -n 8 "$logfile")
    rm -f "$logfile"
    if [ "$result" -ne 0 ]; then
        log_error "dnsmasq: перезапуск не завершён успешно: $output"
        return 1
    fi
    while [ "$attempt" -lt 3 ]; do
        dnsmasq_verify && return 0
        attempt=$((attempt + 1))
        [ "$attempt" -ge 3 ] || sleep 1
    done
    log_error "dnsmasq: после перезапуска локальный DNS не отвечает"
    return 1
}

# Переключён ли dnsmasq нами.
#
# Признаком был сохранённый список прежних серверов. На чистом роутере
# серверов нет, сохранять нечего — и признака не было тоже. Остановка
# считала, что dnsmasq не трогали, и оставляла клиентов без имён, а каждый
# запуск переключал заново и записывал в «прежние» значения свои же
# noresolv=1 и cachesize=0. Проверено на чистой OpenWrt 25.12.
dnsmasq_configured() {
    [ "$(uci -q get "dhcp.@dnsmasq[0].xkop_restore_pending" 2> /dev/null)" = "1" ] && return 0
    [ "$(uci -q get "dhcp.@dnsmasq[0].xkop_managed" 2> /dev/null)" = "1" ] && return 0
    uci -q get "dhcp.@dnsmasq[0].xkop_server" > /dev/null 2>&1 && return 0
    # Роутер, переключённый до появления признака.
    uci -q get "dhcp.@dnsmasq[0].server" 2> /dev/null | tr ' ' '\n' \
        | grep -qxF "$XKOP_DNS_INBOUND_ADDRESS"
}

dnsmasq_backup_option() {
    local key="$1" backup="$2" value
    value=$(uci -q get "dhcp.@dnsmasq[0].$key" 2> /dev/null)
    uci -q set "dhcp.@dnsmasq[0].$backup=${value:-$XKOP_DNSMASQ_UNSET}"
}

dnsmasq_delete_option() {
    if uci -q get "$1" > /dev/null 2>&1; then
        uci -q delete "$1" || return 1
    fi
    return 0
}

# Вернуть сохранённое значение. Копии, которой нельзя верить, — только снять
# своё: dnsmasq без noresolv и с кэшем по умолчанию резолвит всегда.
dnsmasq_restore_option() {
    local key="$1" backup="$2" trusted="$3" value
    value=$(uci -q get "dhcp.@dnsmasq[0].$backup" 2> /dev/null)
    if [ "$trusted" = "1" ] && [ -n "$value" ] && [ "$value" != "$XKOP_DNSMASQ_UNSET" ]; then
        uci -q set "dhcp.@dnsmasq[0].$key=$value"
    else
        dnsmasq_delete_option "dhcp.@dnsmasq[0].$key"
    fi
}

dnsmasq_configure() {
    if dnsmasq_configure_changes; then return 0; fi
    # Discard partial writes; a failed restart retains its committed backup.
    uci -q revert dhcp
    return 1
}

dnsmasq_configure_changes() {
    local current server

    if [ "$(config_uci_get settings dont_touch_dhcp)" = "1" ]; then
        log_info "dnsmasq не трогаем по настройке dont_touch_dhcp"
        return 0
    fi

    command -v uci > /dev/null 2>&1 || return 1
    [ -f "$XKOP_DNSMASQ_INIT" ] || return 1

    if dnsmasq_configured; then
        if [ "$(uci -q get "dhcp.@dnsmasq[0].xkop_restore_pending" 2> /dev/null)" = "1" ]; then
            dnsmasq_restore || return 1
        else
            dnsmasq_verify || dnsmasq_restart_checked
            return $?
        fi
    fi

    # Everything that was there is kept, minus our own address if it somehow
    # already is: restoring must not resurrect a pointer at a stopped engine.
    current=$(uci -q get "dhcp.@dnsmasq[0].server" 2> /dev/null)
    for server in $current; do
        [ "$server" = "$XKOP_DNS_INBOUND_ADDRESS" ] && continue
        # Заглушка для Firefox — наша, её снимает dnsmasq_protection_clear.
        # Сохранённая как «прежняя», она возвращалась после остановки.
        [ "$server" = "/use-application-dns.net/" ] && continue
        uci -q add_list "dhcp.@dnsmasq[0].xkop_server=$server" || return 1
    done

    dnsmasq_backup_option noresolv xkop_noresolv || return 1
    dnsmasq_backup_option cachesize xkop_cachesize || return 1

    dnsmasq_delete_option "dhcp.@dnsmasq[0].server" || return 1
    uci -q add_list "dhcp.@dnsmasq[0].server=$XKOP_DNS_INBOUND_ADDRESS" || return 1
    uci -q set "dhcp.@dnsmasq[0].noresolv=1" || return 1
    # Caching happens in the engine, where a faked answer is bound to a name.
    # A second cache in front of it would hand out addresses the engine no
    # longer knows anything about.
    uci -q set "dhcp.@dnsmasq[0].cachesize=0" || return 1
    uci -q set "dhcp.@dnsmasq[0].xkop_managed=1" || return 1
    uci -q commit dhcp || return 1

    dnsmasq_restart_checked || return 1
    log_info "dnsmasq переключён на $XKOP_DNS_INBOUND_ADDRESS"
}

# Protection from clients resolving around us. The engine cannot do this part:
# it matches names, not record types, and these are record types. dnsmasq can,
# through filter-rr, and the option is checked against the OpenWrt init script
# rather than remembered.
#
#   HTTPS records carry the DoH endpoints browsers auto-discover. Dropping them
#   is what keeps a browser asking us instead of resolving on its own.
#   PTR from Apple devices otherwise costs tens of seconds of mDNS timeouts.
#
# Both are off unless asked for: filtering record types is a blunt instrument
# and someone may be relying on them.
dnsmasq_protection() {
    local https ptr canary changed=0

    https=$(config_uci_get settings block_https_records)
    ptr=$(config_uci_get settings block_ptr_records)
    canary=$(config_uci_get settings block_firefox_canary)

    dnsmasq_delete_option "dhcp.@dnsmasq[0].filter_rr" || return 1

    if [ "$https" = "1" ]; then
        uci -q add_list "dhcp.@dnsmasq[0].filter_rr=HTTPS" || return 1
        changed=1
    fi
    if [ "$ptr" = "1" ]; then
        uci -q add_list "dhcp.@dnsmasq[0].filter_rr=PTR" || return 1
        changed=1
    fi

    # Firefox asks this name before turning its own DoH on. An empty answer
    # from us is the documented way to say "not here".
    if [ "$canary" = "1" ]; then
        # Список, а не значение: без проверки каждый запуск добавлял копию.
        uci -q get "dhcp.@dnsmasq[0].server" 2> /dev/null | tr ' ' '\n' \
            | grep -qxF "/use-application-dns.net/" \
            || uci -q add_list "dhcp.@dnsmasq[0].server=/use-application-dns.net/" || return 1
        changed=1
    fi

    if [ "$changed" -eq 1 ]; then
        uci -q commit dhcp || return 1
        dnsmasq_restart_checked || return 1
        log_info "фильтры записей DNS применены"
    fi
}

# Removed separately from the resolver switch: the filters can be on while the
# DNS mode is off, and then there is no server backup to hang the cleanup on.
# Left behind, they would keep filtering long after xkop stopped.
dnsmasq_protection_clear() {
    local changed=0

    if uci -q get "dhcp.@dnsmasq[0].filter_rr" > /dev/null 2>&1; then
        uci -q delete "dhcp.@dnsmasq[0].filter_rr" || return 1
        changed=1
    fi

    if uci -q get "dhcp.@dnsmasq[0].server" 2> /dev/null | grep -q 'use-application-dns.net'; then
        uci -q del_list "dhcp.@dnsmasq[0].server=/use-application-dns.net/" 2> /dev/null || return 1
        changed=1
    fi

    if [ "$changed" -eq 1 ]; then
        uci -q commit dhcp || return 1
        if [ "${1:-}" != defer ]; then
            dnsmasq_restart_checked || return 1
            log_info "фильтры записей DNS сняты"
        fi
    fi
}

# Remove filters and restore the resolver with one checked restart.
dnsmasq_cleanup() {
    local managed=0 filters=0
    dnsmasq_configured && managed=1
    if uci -q get "dhcp.@dnsmasq[0].filter_rr" > /dev/null 2>&1 \
        || uci -q get "dhcp.@dnsmasq[0].server" 2>/dev/null | grep -q 'use-application-dns.net'; then
        filters=1
    fi
    dnsmasq_protection_clear defer || return 1
    if [ "$managed" = 1 ]; then
        dnsmasq_restore
    elif [ "$filters" = 1 ]; then
        dnsmasq_restart_checked
    else
        dnsmasq_verify || dnsmasq_restart_checked
    fi
}

dnsmasq_restore() {
    local value trusted=1

    dnsmasq_configured || return 0

    # Без признака копии noresolv и cachesize могли быть переписаны нашими же
    # значениями при повторном запуске. Верить им можно, только если прежние
    # серверы были: тогда признаком служили они, и повторного переключения
    # не случалось.
    if [ "$(uci -q get "dhcp.@dnsmasq[0].xkop_managed" 2> /dev/null)" != "1" ] \
        && ! uci -q get "dhcp.@dnsmasq[0].xkop_server" > /dev/null 2>&1; then
        trusted=0
    fi

    uci -q set "dhcp.@dnsmasq[0].xkop_restore_pending=1" || return 1
    dnsmasq_delete_option "dhcp.@dnsmasq[0].server" || return 1
    for value in $(uci -q get "dhcp.@dnsmasq[0].xkop_server" 2> /dev/null); do
        [ "$value" = "$XKOP_DNS_INBOUND_ADDRESS" ] && continue
        uci -q add_list "dhcp.@dnsmasq[0].server=$value" || return 1
    done
    dnsmasq_delete_option "dhcp.@dnsmasq[0].filter_rr" || return 1

    dnsmasq_restore_option noresolv xkop_noresolv "$trusted" || return 1
    dnsmasq_restore_option cachesize xkop_cachesize "$trusted" || return 1

    uci -q commit dhcp || return 1
    dnsmasq_restart_checked || return 1
    if ! { dnsmasq_delete_option "dhcp.@dnsmasq[0].xkop_server" \
        && dnsmasq_delete_option "dhcp.@dnsmasq[0].xkop_noresolv" \
        && dnsmasq_delete_option "dhcp.@dnsmasq[0].xkop_cachesize" \
        && dnsmasq_delete_option "dhcp.@dnsmasq[0].xkop_managed" \
        && dnsmasq_delete_option "dhcp.@dnsmasq[0].xkop_restore_pending"; }; then
        uci -q revert dhcp
        return 1
    fi
    if ! uci -q commit dhcp; then
        uci -q revert dhcp
        log_error "dnsmasq: не удалось сохранить подтверждение восстановления"
        return 1
    fi
    log_info "dnsmasq возвращён в прежнее состояние"
}
