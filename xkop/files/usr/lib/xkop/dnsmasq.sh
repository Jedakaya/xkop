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

# Переключён ли dnsmasq нами.
#
# Признаком был сохранённый список прежних серверов. На чистом роутере
# серверов нет, сохранять нечего — и признака не было тоже. Остановка
# считала, что dnsmasq не трогали, и оставляла клиентов без имён, а каждый
# запуск переключал заново и записывал в «прежние» значения свои же
# noresolv=1 и cachesize=0. Проверено на чистой OpenWrt 25.12.
dnsmasq_configured() {
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

# Вернуть сохранённое значение. Копии, которой нельзя верить, — только снять
# своё: dnsmasq без noresolv и с кэшем по умолчанию резолвит всегда.
dnsmasq_restore_option() {
    local key="$1" backup="$2" trusted="$3" value
    value=$(uci -q get "dhcp.@dnsmasq[0].$backup" 2> /dev/null)
    if [ "$trusted" = "1" ] && [ -n "$value" ] && [ "$value" != "$XKOP_DNSMASQ_UNSET" ]; then
        uci -q set "dhcp.@dnsmasq[0].$key=$value"
    else
        uci -q delete "dhcp.@dnsmasq[0].$key"
    fi
    uci -q delete "dhcp.@dnsmasq[0].$backup"
}

dnsmasq_configure() {
    local current server

    if [ "$(config_uci_get settings dont_touch_dhcp)" = "1" ]; then
        log_info "dnsmasq не трогаем по настройке dont_touch_dhcp"
        return 0
    fi

    command -v uci > /dev/null 2>&1 || return 1
    [ -f "$XKOP_DNSMASQ_INIT" ] || return 1

    if dnsmasq_configured; then
        return 0
    fi

    # Everything that was there is kept, minus our own address if it somehow
    # already is: restoring must not resurrect a pointer at a stopped engine.
    current=$(uci -q get "dhcp.@dnsmasq[0].server" 2> /dev/null)
    for server in $current; do
        [ "$server" = "$XKOP_DNS_INBOUND_ADDRESS" ] && continue
        # Заглушка для Firefox — наша, её снимает dnsmasq_protection_clear.
        # Сохранённая как «прежняя», она возвращалась после остановки.
        [ "$server" = "/use-application-dns.net/" ] && continue
        uci -q add_list "dhcp.@dnsmasq[0].xkop_server=$server"
    done

    dnsmasq_backup_option noresolv xkop_noresolv
    dnsmasq_backup_option cachesize xkop_cachesize

    uci -q delete "dhcp.@dnsmasq[0].server"
    uci -q add_list "dhcp.@dnsmasq[0].server=$XKOP_DNS_INBOUND_ADDRESS"
    uci -q set "dhcp.@dnsmasq[0].noresolv=1"
    # Caching happens in the engine, where a faked answer is bound to a name.
    # A second cache in front of it would hand out addresses the engine no
    # longer knows anything about.
    uci -q set "dhcp.@dnsmasq[0].cachesize=0"
    uci -q set "dhcp.@dnsmasq[0].xkop_managed=1"
    uci -q commit dhcp

    "$XKOP_DNSMASQ_INIT" restart > /dev/null 2>&1
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

    uci -q delete "dhcp.@dnsmasq[0].filter_rr" 2> /dev/null

    if [ "$https" = "1" ]; then
        uci -q add_list "dhcp.@dnsmasq[0].filter_rr=HTTPS"
        changed=1
    fi
    if [ "$ptr" = "1" ]; then
        uci -q add_list "dhcp.@dnsmasq[0].filter_rr=PTR"
        changed=1
    fi

    # Firefox asks this name before turning its own DoH on. An empty answer
    # from us is the documented way to say "not here".
    if [ "$canary" = "1" ]; then
        # Список, а не значение: без проверки каждый запуск добавлял копию.
        uci -q get "dhcp.@dnsmasq[0].server" 2> /dev/null | tr ' ' '\n' \
            | grep -qxF "/use-application-dns.net/" \
            || uci -q add_list "dhcp.@dnsmasq[0].server=/use-application-dns.net/"
        changed=1
    fi

    if [ "$changed" -eq 1 ]; then
        uci -q commit dhcp
        "$XKOP_DNSMASQ_INIT" restart > /dev/null 2>&1
        log_info "фильтры записей DNS применены"
    fi
}

# Removed separately from the resolver switch: the filters can be on while the
# DNS mode is off, and then there is no server backup to hang the cleanup on.
# Left behind, they would keep filtering long after xkop stopped.
dnsmasq_protection_clear() {
    local changed=0

    if uci -q get "dhcp.@dnsmasq[0].filter_rr" > /dev/null 2>&1; then
        uci -q delete "dhcp.@dnsmasq[0].filter_rr"
        changed=1
    fi

    if uci -q get "dhcp.@dnsmasq[0].server" 2> /dev/null | grep -q 'use-application-dns.net'; then
        uci -q del_list "dhcp.@dnsmasq[0].server=/use-application-dns.net/" 2> /dev/null
        changed=1
    fi

    if [ "$changed" -eq 1 ]; then
        uci -q commit dhcp
        "$XKOP_DNSMASQ_INIT" restart > /dev/null 2>&1
        log_info "фильтры записей DNS сняты"
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

    uci -q delete "dhcp.@dnsmasq[0].server"
    for value in $(uci -q get "dhcp.@dnsmasq[0].xkop_server" 2> /dev/null); do
        [ "$value" = "$XKOP_DNS_INBOUND_ADDRESS" ] && continue
        uci -q add_list "dhcp.@dnsmasq[0].server=$value"
    done
    uci -q delete "dhcp.@dnsmasq[0].xkop_server"
    uci -q delete "dhcp.@dnsmasq[0].filter_rr" 2> /dev/null

    dnsmasq_restore_option noresolv xkop_noresolv "$trusted"
    dnsmasq_restore_option cachesize xkop_cachesize "$trusted"
    uci -q delete "dhcp.@dnsmasq[0].xkop_managed"

    uci -q commit dhcp
    "$XKOP_DNSMASQ_INIT" restart > /dev/null 2>&1
    log_info "dnsmasq возвращён в прежнее состояние"
}
