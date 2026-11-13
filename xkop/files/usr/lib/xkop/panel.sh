#!/bin/sh
# shellcheck shell=ash
# Shared by the installer and service. No implicit package installation or HTTP
# fallback: use the existing LuCI certificate and uhttpd TLS backend.

panel_tls_configure() {
    local root="$1" section="$2" port="$3" cert key changed=0 ready=1
    command -v uci >/dev/null 2>&1 || return 1
    [ -x /etc/init.d/uhttpd ] && [ -s "$root/index.html" ] || return 1
    cert=$(uci -q get uhttpd.main.cert 2>/dev/null) || cert=
    key=$(uci -q get uhttpd.main.key 2>/dev/null) || key=
    cert=${cert:-/etc/uhttpd.crt}
    key=${key:-/etc/uhttpd.key}
    [ -r "$cert" ] && [ -s "$cert" ] && [ -r "$key" ] && [ -s "$key" ] || ready=0
    [ -r /lib/libustream-ssl.so ] || [ -r /usr/lib/libustream-ssl.so ] || ready=0
    command -v ubus >/dev/null 2>&1 || ready=0

    if [ "$section" != xkop ] && [ "$(uci -q get uhttpd.xkop.home 2>/dev/null)" = "$root" ]; then
        uci -q delete uhttpd.xkop || return 1
        changed=1
    fi
    if [ "$ready" -eq 0 ]; then
        # Remove the previous plaintext instance even when HTTPS cannot start.
        if uci -q get "uhttpd.$section.home" >/dev/null 2>&1; then
            uci -q delete "uhttpd.$section" || return 1
            changed=1
        fi
        if [ "$changed" -eq 1 ]; then
            uci commit uhttpd || return 1
            /etc/init.d/uhttpd reload >/dev/null 2>&1 || return 1
        fi
        echo 'xkop: client panel disabled; configure the existing uhttpd TLS certificate/key and rpcd first' >&2
        return 1
    fi

    if [ "$changed" -eq 0 ] \
        && [ "$(uci -q get "uhttpd.$section.home" 2>/dev/null)" = "$root" ] \
        && [ -z "$(uci -q get "uhttpd.$section.listen_http" 2>/dev/null)" ] \
        && [ "$(uci -q get "uhttpd.$section.listen_https" 2>/dev/null)" = "0.0.0.0:$port" ] \
        && [ "$(uci -q get "uhttpd.$section.cert" 2>/dev/null)" = "$cert" ] \
        && [ "$(uci -q get "uhttpd.$section.key" 2>/dev/null)" = "$key" ]; then
        return 0
    fi
    uci -q delete "uhttpd.$section" 2>/dev/null || :
    uci set "uhttpd.$section=uhttpd" \
        && uci add_list "uhttpd.$section.listen_https=0.0.0.0:$port" \
        && uci set "uhttpd.$section.cert=$cert" \
        && uci set "uhttpd.$section.key=$key" \
        && uci set "uhttpd.$section.home=$root" \
        && uci set "uhttpd.$section.cgi_prefix=/cgi-bin" \
        && uci set "uhttpd.$section.index_page=index.html" \
        && uci set "uhttpd.$section.script_timeout=60" \
        && uci set "uhttpd.$section.network_timeout=30" \
        && uci commit uhttpd || return 1
    /etc/init.d/uhttpd reload >/dev/null 2>&1
}
