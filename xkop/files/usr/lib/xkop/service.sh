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
        echo "$minute * * * * /usr/bin/xkop subscription_refresh > /dev/null 2>&1 $XKOP_CRON_MARKER"
        echo "$minute 5 * * * /usr/bin/xkop configure > /dev/null 2>&1 $XKOP_CRON_MARKER"
        echo "$minute 4 * * * /usr/bin/xkop lists_update > /dev/null 2>&1 $XKOP_CRON_MARKER"
        echo "$minute 4 * * * /usr/bin/xkop userlists_update > /dev/null 2>&1 $XKOP_CRON_MARKER"
        echo "*/17 * * * * /usr/bin/xkop canary > /dev/null 2>&1 $XKOP_CRON_MARKER"
        echo "*/10 * * * * /usr/bin/xkop access_trim > /dev/null 2>&1 $XKOP_CRON_MARKER"
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

# Is the engine process alive.
#
# pgrep alone was not enough: it is a busybox applet that a build can leave
# out, and when it is missing the answer comes back "not running" for an engine
# that is serving traffic and answering its own metrics endpoint. The whole
# overview then contradicts itself - traffic counted, service stopped.
#
# /proc is always there, so it is the fallback: comm holds the executable name
# for every live process.
engine_process_running() {
    local name="${XKOP_ENGINE_BIN:-xray}" comm

    if command -v pgrep > /dev/null 2>&1; then
        pgrep -x "$name" > /dev/null 2>&1 && return 0
    fi

    for comm in /proc/[0-9]*/comm; do
        [ -r "$comm" ] || continue
        read -r found < "$comm" 2> /dev/null || continue
        [ "$found" = "$name" ] && return 0
    done

    return 1
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
    userlist_update_all > /dev/null 2>&1

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

    dnsmasq_protection

    # Панель отдаётся, только если её файлы на месте: пакет её не несёт,
    # её кладёт установщик или выкладка со стенда.
    panel_present && panel_configure_uhttpd

    return 0
}

service_teardown() {
    nft_clear
    dnsmasq_protection_clear
    dnsmasq_restore
}

# Интернет поднялся. Это важный момент: при старте роутера WAN обычно ещё
# не готов, подписки не приезжают, и роутер поднимается на кэше или без
# узлов вовсе. Здесь он добирает то, что не смог.
#
# Ничего не перезапускается без нужды. Работающий движок трогать на каждое
# мигание интерфейса — это способ уронить то, что работало.
service_on_wan_up() {
    local restart=0

    if ! nft_present; then
        log_info "правила nft отсутствуют, применяю заново"
        nft_apply || true
    fi

    lists_present || lists_update

    # Спрашиваются только те подписки, которым пора, плюс те, у кого пусто:
    # именно они и есть причина, по которой мы сюда пришли.
    subscription_update_all

    if [ "$(subscription_pool_all | jq 'length' 2> /dev/null)" != "0" ]; then
        config_generate && restart=1
    fi

    if [ "$restart" -eq 1 ]; then
        log_info "после подъёма WAN появились узлы, перезапускаю движок"
        /etc/init.d/xkop restart > /dev/null 2>&1 &
    fi
}

# One door for the interface. LuCI could call /etc/init.d/xkop itself, but then
# the answer to "did it work" would be an exit code of the init script, which
# says nothing about whether the engine came up. Here the action is followed by
# the same status the overview shows.
service_control() {
    local action="${1:-status}"

    case "$action" in
        start | stop | restart)
            /etc/init.d/xkop "$action" > /dev/null 2>&1
            ;;
        enable | disable)
            /etc/init.d/xkop "$action" > /dev/null 2>&1
            ;;
        status) ;;
        *)
            jq -nc --arg a "$action" '{ok: false, error: "unknown_action", detail: {action: $a}}'
            return 0
            ;;
    esac

    # A start that returned zero and an engine that is actually up are not the
    # same thing, and telling them apart is the whole point of asking.
    #
    # Eight seconds, not twenty: the call comes from LuCI over rpcd, and rpcd
    # gives up on it long before twenty. The interface then reported
    # not_reachable for a start that was working - the wait outlived the caller.
    # What the wait misses, the overview picks up on its next refresh.
    case "$action" in
        start | restart) engine_wait 8 > /dev/null 2>&1 ;;
    esac

    jq -nc --arg a "$action" --argjson status "$(service_status_json)" \
        '{ok: true, action: $a} + $status'
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

# Панель конечного пользователя: отдельный экземпляр uhttpd на своём порту.
# Основной интерфейс роутера при этом не трогается — на нём живёт LuCI,
# и делить с ним настройки значит однажды уронить оба.
panel_configure_uhttpd() {
    command -v uci > /dev/null 2>&1 || return 1
    [ -f /etc/init.d/uhttpd ] || return 1
    [ -s "$XKOP_PANEL_ROOT/index.html" ] || return 1

    uci -q delete "uhttpd.$XKOP_PANEL_SECTION"
    uci -q set "uhttpd.$XKOP_PANEL_SECTION=uhttpd"
    uci -q add_list "uhttpd.$XKOP_PANEL_SECTION.listen_http=0.0.0.0:$XKOP_PANEL_PORT"
    uci -q set "uhttpd.$XKOP_PANEL_SECTION.home=$XKOP_PANEL_ROOT"
    uci -q set "uhttpd.$XKOP_PANEL_SECTION.cgi_prefix=/cgi-bin"
    uci -q set "uhttpd.$XKOP_PANEL_SECTION.index_page=index.html"
    uci -q set "uhttpd.$XKOP_PANEL_SECTION.script_timeout=60"
    uci -q set "uhttpd.$XKOP_PANEL_SECTION.network_timeout=30"
    uci -q commit uhttpd

    /etc/init.d/uhttpd restart > /dev/null 2>&1
    log_info "панель клиента отдаётся на порту $XKOP_PANEL_PORT"
}

panel_remove_uhttpd() {
    uci -q get "uhttpd.$XKOP_PANEL_SECTION" > /dev/null 2>&1 || return 0
    uci -q delete "uhttpd.$XKOP_PANEL_SECTION"
    uci -q commit uhttpd
    /etc/init.d/uhttpd restart > /dev/null 2>&1
}

panel_present() {
    [ -s "$XKOP_PANEL_ROOT/index.html" ] && [ -x "$XKOP_PANEL_ROOT/cgi-bin/status" ]
}
