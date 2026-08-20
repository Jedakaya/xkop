#!/bin/sh
# shellcheck shell=ash
# Lists of domains the routing rules refer to.
#
# The engine resolves "geosite:russia-inside" when it loads the configuration,
# and without the file it refuses the whole configuration - not the one rule.
# So the list is a hard dependency of a working router, and it is treated like
# one: downloaded into RAM, proven by the engine itself, and only then put on
# flash.
#
# The file comes from itdoginfo/allow-domains and is about 90 KB, against the
# ten megabytes of the standard geosite.dat. That difference is the whole
# reason it is worth having on a router.

XKOP_ASSET_DIR='/usr/share/xray'
XKOP_GEOSITE_URL='https://github.com/itdoginfo/allow-domains/releases/latest/download/geosite.dat'

# A category known to be in that file. Used to prove a downloaded copy is
# actually loadable before it replaces the working one.
XKOP_GEOSITE_PROBE='russia-inside'

lists_geosite_path() {
    printf '%s/geosite.dat' "$XKOP_ASSET_DIR"
}

lists_present() {
    [ -s "$(lists_geosite_path)" ]
}

# The engine decides whether the file is good, the same way it decides about a
# configuration. A truncated download parses as a file and fails as a list.
lists_validate() {
    local candidate="$1" dir engine probe
    engine=$(config_engine_bin)
    command -v "$engine" > /dev/null 2>&1 || return 2

    dir="$XKOP_RUN_DIR/assets"
    rm -rf "$dir"
    mkdir -p "$dir"
    cp "$candidate" "$dir/geosite.dat" || return 1

    probe="$XKOP_RUN_DIR/geosite-probe.json"
    jq -nc --arg category "geosite:$XKOP_GEOSITE_PROBE" \
        '{log: {loglevel: "error"},
          outbounds: [{tag: "direct", protocol: "freedom"}],
          routing: {rules: [{type: "field", domain: [$category], outboundTag: "direct"}]}}' \
        > "$probe"

    XRAY_LOCATION_ASSET="$dir" "$engine" run -test -format json -c "$probe" > /dev/null 2>&1
}

# Пора ли обновлять список по настройке lists_update_interval. Настройка
# существовала и не читалась никем: список качался по расписанию cron, а
# значение в конфигурации выглядело действующим. Теперь оно и решает.
lists_due() {
    local interval age target now mtime

    target=$(lists_geosite_path)
    [ -f "$target" ] || return 0

    interval=$(config_uci_get settings lists_update_interval 2> /dev/null)
    [ -n "$interval" ] || interval="1d"
    age=$(subscription_interval_seconds "$interval")
    [ -n "$age" ] && [ "$age" -gt 0 ] || return 0

    now=$(date +%s 2> /dev/null)
    mtime=$(date -r "$target" +%s 2> /dev/null)
    case "$now$mtime" in
        '' | *[!0-9]*) return 0 ;;
    esac

    [ "$((now - mtime))" -ge "$age" ]
}

lists_update() {
    local tmp size_kb free_kb target
    target=$(lists_geosite_path)
    mkdir -p "$XKOP_RUN_DIR" "$XKOP_ASSET_DIR"

    if [ "${1:-}" != "force" ] && ! lists_due; then
        return 2
    fi

    # RAM first: a failed download must cost no flash and leave the working
    # list exactly where it was.
    tmp="$XKOP_RUN_DIR/geosite.dat"
    if ! curl -fsSL --max-time 120 -o "$tmp" "$XKOP_GEOSITE_URL" 2> /dev/null; then
        log_warn "список доменов не скачался, остаётся прежний"
        return 1
    fi

    if ! lists_validate "$tmp"; then
        case "$?" in
            2) log_warn "движка нет, список не проверен и не установлен" ;;
            *) log_error "скачанный список движок не принял, остаётся прежний" ;;
        esac
        rm -f "$tmp"
        return 1
    fi

    if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
        rm -f "$tmp"
        return 2
    fi

    size_kb=$(( ($(wc -c < "$tmp") + 1023) / 1024 ))
    free_kb=$(df -k "$XKOP_ASSET_DIR" | awk 'NR==2 {print $4}')
    if [ -n "$free_kb" ] && [ "$free_kb" -lt "$size_kb" ]; then
        log_error "не хватает места под список: нужно ${size_kb} КБ, свободно ${free_kb} КБ"
        rm -f "$tmp"
        return 1
    fi

    cp "$tmp" "$target.tmp" && mv "$target.tmp" "$target"
    rm -f "$tmp"
    log_info "список доменов обновлён, ${size_kb} КБ"
    return 0
}
