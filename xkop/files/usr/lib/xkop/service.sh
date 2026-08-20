#!/bin/sh
# shellcheck shell=ash
# Service lifecycle: what happens on start, in what order, and what must not
# stop it.
#
# The order is not a matter of taste. Every line of it was bought with a router
# that had to be recovered by hand:
#
#   1. scheduled jobs FIRST. If generation fails afterwards, the router still
#      has a way back - a refresh will come and fix it by itself. Installed
#      last, a failed generation leaves the device with no path to recovery at
#      all.
#   2. subscriptions refresh, but the cache is the source of truth. A router
#      with no internet must still come up routing.
#   3. configuration is generated and validated; an invalid one is not
#      installed and does not cancel the start - the engine keeps the last one
#      that worked.
#   4. firewall rules last, when there is something to send traffic to.
#
# And after the engine is asked to start, that it actually came up is checked,
# not assumed. A process in the list proves nothing: it may be the old one.

XKOP_CRON_MARKER='# xkop'

# The minute is derived from the router's own identity and never moves. A
# hundred routers knocking on the same panel at the top of the hour is a load
# we would be creating ourselves; a minute drawn fresh every cycle would make
# the interval itself drift.
cron_minute() {
    local raw
    raw=$(subscription_hwid | md5sum | cut -c1-4)
    printf '%s' $(( 0x$raw % 60 ))
}

cron_install() {
    local crontab='/etc/crontabs/root' minute tmp

    command -v crontab > /dev/null 2>&1 || return 0
    minute=$(cron_minute)
    tmp="$XKOP_RUN_DIR/crontab"
    mkdir -p "$XKOP_RUN_DIR" /etc/crontabs

    grep -v "$XKOP_CRON_MARKER" "$crontab" 2> /dev/null > "$tmp" || true
    {
        echo "$minute * * * * /usr/bin/xkop subscription_update > /dev/null 2>&1 $XKOP_CRON_MARKER"
        echo "$minute 5 * * * /usr/bin/xkop configure > /dev/null 2>&1 $XKOP_CRON_MARKER"
        echo "$minute 4 * * * /usr/bin/xkop lists_update > /dev/null 2>&1 $XKOP_CRON_MARKER"
    } >> "$tmp"

    if ! cmp -s "$tmp" "$crontab" 2> /dev/null; then
        cp "$tmp" "$crontab.tmp" && mv "$crontab.tmp" "$crontab"
        /etc/init.d/cron reload > /dev/null 2>&1 || /etc/init.d/cron restart > /dev/null 2>&1 || true
        log_info "задачи по расписанию установлены, минута $minute"
    fi
    rm -f "$tmp"
}

cron_remove() {
    local crontab='/etc/crontabs/root' tmp
    [ -f "$crontab" ] || return 0
    tmp="$XKOP_RUN_DIR/crontab"
    mkdir -p "$XKOP_RUN_DIR"
    grep -v "$XKOP_CRON_MARKER" "$crontab" > "$tmp" 2> /dev/null || true
    cp "$tmp" "$crontab.tmp" && mv "$crontab.tmp" "$crontab"
    rm -f "$tmp"
    /etc/init.d/cron reload > /dev/null 2>&1 || true
}

engine_process_running() {
    pgrep -x "${XKOP_ENGINE_BIN:-xray}" > /dev/null 2>&1
}

# Proof, not assumption: the metrics endpoint answers only when the engine is
# up and running our configuration. A pid says nothing about which one.
engine_answers() {
    curl -fsS -m 2 -o /dev/null "http://$XKOP_METRICS_HOST:$(metrics_port)$XKOP_METRICS_PATH" 2> /dev/null
}

engine_wait() {
    local deadline=${1:-15} waited=0

    while [ "$waited" -lt "$deadline" ]; do
        engine_answers && return 0
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

# Everything that has to happen before the engine is started, in the order it
# has to happen in.
service_prepare() {
    mkdir -p "$XKOP_RUN_DIR" "$XKOP_STATE_DIR" "$XKOP_CACHE_DIR"

    cron_install

    # Списки нужны движку в момент загрузки конфигурации: правило geosite он
    # разворачивает сразу, и без файла отвергает конфигурацию целиком.
    lists_present || lists_update

    subscription_update_all

    if config_generate; then
        :
    else
        if [ -f "$XKOP_CONFIG_PATH" ]; then
            log_warn "новая конфигурация не принята, работаю на прежней"
        else
            log_error "конфигурации нет и собрать её не удалось, движку нечего запускать"
            return 1
        fi
    fi

    nft_apply || log_warn "правила nft не применены, трафик в движок не пойдёт"

    # Резолвер трогается только в режиме fakeip. В обычном режиме имена
    # распознаются по самому соединению, и dnsmasq остаётся как был.
    if [ "$(config_uci_get settings dns_mode)" = "fakeip" ]; then
        dnsmasq_configure || log_warn "dnsmasq не переключён, поддельные адреса выдавать некому"
    else
        dnsmasq_restore
    fi

    return 0
}

service_teardown() {
    nft_clear
    dnsmasq_restore
}

service_status_json() {
    local enabled=0 running=0 answering=0 nodes=0

    [ -x /etc/rc.d/S99xkop ] && enabled=1
    engine_process_running && running=1
    engine_answers && answering=1
    nodes=$(subscription_pool_all | jq 'length' 2> /dev/null)
    [ -n "$nodes" ] || nodes=0

    jq -nc \
        --argjson enabled "$enabled" --argjson running "$running" \
        --argjson answering "$answering" --argjson nodes "$nodes" \
        --argjson config "$([ -f "$XKOP_CONFIG_PATH" ] && echo true || echo false)" \
        --argjson rules "$(nft_present && echo true || echo false)" \
        '{
            ok: true,
            enabled: ($enabled == 1),
            engine: {running: ($running == 1), answering: ($answering == 1)},
            config_present: $config,
            nft_rules: $rules,
            nodes: $nodes,
            state: (
                if ($running == 1) and ($answering == 1) and $rules then "работает"
                elif ($running == 1) and ($answering == 0) then "движок запущен, но не отвечает"
                elif ($running == 1) then "движок работает, правила не применены"
                else "остановлен"
                end
            )
        }'
}
