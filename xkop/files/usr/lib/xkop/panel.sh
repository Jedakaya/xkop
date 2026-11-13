#!/bin/sh
# shellcheck shell=ash
# Shared by the installer and service. No implicit package installation or HTTP
# fallback: use the existing LuCI certificate and uhttpd TLS backend.

panel_bundle_valid() {
    local bundle="$1" name
    [ -r "$bundle/index.html" ] && [ -s "$bundle/index.html" ] || return 1
    for name in _common auth status subscription-set subscription-update routes route-set node-select explain; do
        [ -r "$bundle/cgi-bin/$name" ] && [ -s "$bundle/cgi-bin/$name" ] \
            && [ -x "$bundle/cgi-bin/$name" ] || return 1
        sh -n "$bundle/cgi-bin/$name" || return 1
    done
}

panel_publish_bundle() {
    local staged="$1" bundle="$2" backup
    panel_bundle_valid "$staged" || return 1
    # The installer stages beside the destination. The listener is stopped
    # before these renames, so neither failures nor a crash expose mixed CGI.
    backup=$(mktemp -d "$bundle.previous.XXXXXX") || return 1
    if [ -e "$bundle" ] && ! mv "$bundle" "$backup/bundle"; then
        rmdir "$backup" 2>/dev/null || :
        return 1
    fi
    if ! mv "$staged" "$bundle"; then
        if [ -d "$backup/bundle" ] && ! mv "$backup/bundle" "$bundle"; then
            echo "xkop: panel restore failed; previous bundle preserved in $backup" >&2
            return 1
        fi
        rmdir "$backup" 2>/dev/null || :
        return 1
    fi
    rm -rf "$backup"
}

panel_mark_enabled() (
    local marker="$1" tmp
    umask 077
    mkdir -p "$(dirname "$marker")" || return 1
    tmp=$(mktemp "$marker.XXXXXX") || return 1
    if ! { printf 'enabled\n' > "$tmp" && mv -f "$tmp" "$marker"; }; then
        rm -f "$tmp"
        return 1
    fi
)

panel_disable() {
    local legacy="$1" section="$2" bundle="${3:-}" changed=0 home
    if uci -q get "uhttpd.$section.home" >/dev/null 2>&1; then
        uci -q delete "uhttpd.$section" || return 1
        changed=1
    fi
    home=$(uci -q get uhttpd.xkop.home 2>/dev/null) || home=
    if [ "$section" != xkop ] && [ -n "$home" ] \
        && { [ "$home" = "$legacy" ] || [ "$home" = "$bundle" ]; }; then
        uci -q delete uhttpd.xkop || return 1
        changed=1
    fi
    [ "$changed" -eq 1 ] || return 0
    uci commit uhttpd && /etc/init.d/uhttpd reload >/dev/null 2>&1
}

panel_configure_bundle() {
    local legacy="$1" bundle="$2" marker="$3" section="$4" port="$5"
    # The bundle is installed on every router, but activation is opt-in state.
    [ -f "$marker" ] || [ -s "$legacy/index.html" ] || return 0
    if ! panel_bundle_valid "$bundle"; then
        panel_disable "$legacy" "$section" "$bundle" || return 1
        echo 'xkop: client panel disabled; package panel bundle is incomplete' >&2
        return 1
    fi
    if [ ! -f "$marker" ] && ! panel_mark_enabled "$marker"; then
        panel_disable "$legacy" "$section" "$bundle" || return 1
        return 1
    fi
    if [ "$(uci -q get "uhttpd.$section.home" 2>/dev/null)" != "$bundle" ]; then
        # Retire credentials issued by the legacy standalone authentication CGI.
        if ! rm -f /tmp/xkop-panel-token; then
            panel_disable "$legacy" "$section" "$bundle" || return 1
            return 1
        fi
    fi
    panel_tls_configure "$bundle" "$section" "$port" "$legacy"
}

panel_tls_configure() {
    local root="$1" section="$2" port="$3" legacy="${4:-$1}" cert key changed=0 ready=1 home
    command -v uci >/dev/null 2>&1 || return 1
    [ -x /etc/init.d/uhttpd ] && [ -s "$root/index.html" ] || return 1
    cert=$(uci -q get uhttpd.main.cert 2>/dev/null) || cert=
    key=$(uci -q get uhttpd.main.key 2>/dev/null) || key=
    cert=${cert:-/etc/uhttpd.crt}
    key=${key:-/etc/uhttpd.key}
    [ -r "$cert" ] && [ -s "$cert" ] && [ -r "$key" ] && [ -s "$key" ] || ready=0
    [ -r /lib/libustream-ssl.so ] || [ -r /usr/lib/libustream-ssl.so ] || ready=0
    command -v ubus >/dev/null 2>&1 || ready=0

    home=$(uci -q get uhttpd.xkop.home 2>/dev/null) || home=
    if [ "$section" != xkop ] && { [ "$home" = "$root" ] || [ "$home" = "$legacy" ]; }; then
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
