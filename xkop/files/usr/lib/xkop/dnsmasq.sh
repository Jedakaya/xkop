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

dnsmasq_configured() {
    uci -q get "dhcp.@dnsmasq[0].xkop_server" > /dev/null 2>&1
}

dnsmasq_backup_option() {
    local key="$1" backup="$2" value
    value=$(uci -q get "dhcp.@dnsmasq[0].$key" 2> /dev/null)
    [ -n "$value" ] && uci -q set "dhcp.@dnsmasq[0].$backup=$value"
}

dnsmasq_configure() {
    local current server

    if [ "$(config_uci_get settings dont_touch_dhcp)" = "1" ]; then
        log_info "dnsmasq не трогаем по настройке dont_touch_dhcp"
        return 0
    fi

    command -v uci > /dev/null 2>&1 || return 1
    [ -f /etc/init.d/dnsmasq ] || return 1

    if dnsmasq_configured; then
        return 0
    fi

    # Everything that was there is kept, minus our own address if it somehow
    # already is: restoring must not resurrect a pointer at a stopped engine.
    current=$(uci -q get "dhcp.@dnsmasq[0].server" 2> /dev/null)
    for server in $current; do
        [ "$server" = "$XKOP_DNS_INBOUND_ADDRESS" ] && continue
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
    uci -q commit dhcp

    /etc/init.d/dnsmasq restart > /dev/null 2>&1
    log_info "dnsmasq переключён на $XKOP_DNS_INBOUND_ADDRESS"
}

dnsmasq_restore() {
    local value

    dnsmasq_configured || return 0

    uci -q delete "dhcp.@dnsmasq[0].server"
    for value in $(uci -q get "dhcp.@dnsmasq[0].xkop_server" 2> /dev/null); do
        uci -q add_list "dhcp.@dnsmasq[0].server=$value"
    done
    uci -q delete "dhcp.@dnsmasq[0].xkop_server"

    value=$(uci -q get "dhcp.@dnsmasq[0].xkop_noresolv" 2> /dev/null)
    if [ -n "$value" ]; then
        uci -q set "dhcp.@dnsmasq[0].noresolv=$value"
        uci -q delete "dhcp.@dnsmasq[0].xkop_noresolv"
    else
        uci -q delete "dhcp.@dnsmasq[0].noresolv"
    fi

    value=$(uci -q get "dhcp.@dnsmasq[0].xkop_cachesize" 2> /dev/null)
    if [ -n "$value" ]; then
        uci -q set "dhcp.@dnsmasq[0].cachesize=$value"
        uci -q delete "dhcp.@dnsmasq[0].xkop_cachesize"
    else
        uci -q delete "dhcp.@dnsmasq[0].cachesize"
    fi

    uci -q commit dhcp
    /etc/init.d/dnsmasq restart > /dev/null 2>&1
    log_info "dnsmasq возвращён в прежнее состояние"
}
