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
        echo "*/5 * * * * /usr/bin/xkop keep > /dev/null 2>&1 $XKOP_CRON_MARKER"
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

# Версия движка с запоминанием.
#
# Спрашивается она запуском самого движка, а обзор спрашивает её на каждой
# отрисовке - лишний запуск бинарника там, где ответ меняется раз в несколько
# месяцев. Запомненное привязано ко времени правки файла: обновился движок -
# ответ пересчитается сам.
engine_version_cached() {
    local bin cache stamp saved
    bin=$(command -v "${XKOP_ENGINE_BIN:-xray}" 2> /dev/null) || return 0
    [ -n "$bin" ] || return 0

    cache="$XKOP_RUN_DIR/engine-version"

    # Отметка файла, по которой узнаётся, что движок сменился.
    #
    # `date -r` есть не во всякой сборке busybox — это записано у нас же,
    # в install.sh, и я это благополучно не учёл. Когда его нет, отметка
    # выходит пустой, ключ совпадает всегда, и кэш отдаёт старую версию
    # вечно: пакет обновился, а интерфейс показывает прежнюю.
    #
    # Поэтому отметка собирается из трёх источников, и если не вышло ни одним,
    # кэш не используется вовсе. Лишний запуск движка дешевле неправды.
    local mtime size
    mtime=$(date -r "$bin" +%s 2> /dev/null)
    case "$mtime" in
        '' | *[!0-9]*) mtime=$(find "$bin" -maxdepth 0 -printf '%T@' 2> /dev/null | cut -d. -f1) ;;
    esac
    case "$mtime" in
        '' | *[!0-9]*) mtime=0 ;;
    esac

    size=$(wc -c < "$bin" 2> /dev/null | tr -d ' ')
    case "$size" in
        '' | *[!0-9]*) size=0 ;;
    esac

    # Ни времени, ни размера — запоминать нечего, спрашиваем движок каждый раз.
    # Лишний запуск дешевле неправды.
    if [ "$mtime" = "0" ] && [ "$size" = "0" ]; then
        "$bin" version 2> /dev/null | head -n 1 | awk '{print $2}'
        return 0
    fi

    # Время И размер: подмена в ту же секунду временем не ловится, а размером
    # ловится, и наоборот.
    stamp="$mtime-$size"

    saved=$(cat "$cache" 2> /dev/null)
    case "$saved" in
        "$stamp "*) printf '%s' "${saved#* }"; return 0 ;;
    esac

    saved=$("$bin" version 2> /dev/null | head -n 1 | awk '{print $2}')
    [ -n "$saved" ] || return 0
    mkdir -p "$XKOP_RUN_DIR"
    printf '%s %s' "$stamp" "$saved" > "$cache"
    printf '%s' "$saved"
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
# Bounded command runner. busybox changed timeout's calling convention: older
# builds expect "timeout -t SECS CMD", newer ones "timeout SECS CMD". Guessing
# wrong does not fail loudly - the old build takes the number for a program
# name - so both forms are probed once against a trivial command.
service_run_bounded() {
    local secs="$1" pid waited=0
    shift

    if timeout 1 true > /dev/null 2>&1; then
        timeout "$secs" "$@" > /dev/null 2>&1
        return 0
    fi

    if timeout -t 1 true > /dev/null 2>&1; then
        timeout -t "$secs" "$@" > /dev/null 2>&1
        return 0
    fi

    "$@" > /dev/null 2>&1 &
    pid=$!
    while [ "$waited" -lt "$secs" ] && kill -0 "$pid" 2> /dev/null; do
        sleep 1
        waited=$((waited + 1))
    done
    kill "$pid" 2> /dev/null
    return 0
}

# Compared against a moment that has demonstrably already passed rather than a
# hardcoded year, which is stale the day it is written.
service_clock_is_plausible() {
    local now ref

    now=$(date +%s 2> /dev/null)
    case "$now" in
        '' | *[!0-9]*) return 1 ;;
    esac

    ref=$(date -r /usr/bin/xkop +%s 2> /dev/null)
    [ -n "$ref" ] || ref=$(date -r /etc/openwrt_release +%s 2> /dev/null)
    case "$ref" in
        '' | *[!0-9]*) return 0 ;;
    esac

    [ "$now" -ge "$ref" ]
}

# DoH and TLS both refuse to work with a clock that is years off, and the error
# they give names the certificate, not the clock. "ntpd -q" returns only once
# the clock is actually set and has no timeout of its own, so unreachable time
# servers hang it forever - which is why the wait is bounded and only happens
# when the clock is known to be wrong.
service_sync_time() {
    [ -x /usr/sbin/ntpd ] || return 0
    service_clock_is_plausible && return 0

    log_info "часы не выставлены, жду синхронизацию (до 60 с)"
    service_run_bounded 60 /usr/sbin/ntpd -q -p 194.190.168.1 -p 216.239.35.0 \
        -p 216.239.35.4 -p 162.159.200.1 -p 162.159.200.123

    service_clock_is_plausible \
        || log_warn "время синхронизировать не удалось, DoH и TLS могут не пройти"
    return 0
}

# With br_netfilter loaded and bridge-nf-call-iptables on, packets bridged
# between LAN ports are handed to netfilter a second time, and the tproxy
# interception then sees traffic it has no business seeing - or misses traffic
# it should. Taken from podkop, where this was found on real hardware.
service_br_netfilter_disable() {
    grep -qs '^br_netfilter ' /proc/modules || return 0
    [ "$(sysctl -n net.bridge.bridge-nf-call-iptables 2> /dev/null)" = "1" ] || return 0

    log_info "br_netfilter включён, выключаю его вмешательство в мост"
    sysctl -w net.bridge.bridge-nf-call-iptables=0 > /dev/null 2>&1
    sysctl -w net.bridge.bridge-nf-call-ip6tables=0 > /dev/null 2>&1
    return 0
}

# What has to be there before anything is attempted. Each answer names what to
# do about it: "не запускается" without a reason is the failure this project
# exists to avoid.
service_check_requirements() {
    local version

    if ! command -v "${XKOP_ENGINE_BIN:-xray}" > /dev/null 2>&1; then
        log_error "движок не установлен: поставьте пакет xray-xkop или запустите xkop update"
        return 1
    fi

    version=$("${XKOP_ENGINE_BIN:-xray}" version 2> /dev/null | head -n 1 | awk '{print $2}')
    if [ -n "$version" ]; then
        # Третий ответ engine_supports — «границу не устанавливали». Молчим
        # именно в нём: выдать незнание за отказ было бы той же ложью.
        engine_supports hysteria2 "$version"
        [ "$?" = "1" ] && log_warn "движок $version старше проверенного $XKOP_MIN_VERSION_HYSTERIA2, Hysteria2 не соберётся"
    fi

    command -v jq > /dev/null 2>&1 \
        || { log_error "нет jq, без него не собрать конфигурацию"; return 1; }
    command -v nft > /dev/null 2>&1 \
        || log_warn "нет nft, правила применить будет нечем"

    # Чужой перехват dnsmasq виден прямо в его настройках, и молча ломает наш.
    if grep -qsE 'doh_backup_noresolv|doh_backup_server|doh_server' /etc/config/dhcp; then
        log_warn "в /etc/config/dhcp следы https-dns-proxy, они мешают нашему DNS"
    fi

    return 0
}

# Обновление списков в фоне, после того как роутер уже поднялся.
#
# Перезапуск делается только когда состав подсетей изменился: обновление ради
# обновления рвало бы соединения на ровном месте раз в час.
lists_refresh_background() {
    local pidfile="$XKOP_RUN_DIR/lists-refresh.pid" pid

    pid=$(cat "$pidfile" 2> /dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2> /dev/null; then
        return 0
    fi

    (
        trap 'rm -f "$pidfile"' EXIT INT TERM
        sleep 20
        if lists_subnets_update; then
            log_info "состав подсетей изменился, пересобираю конфигурацию"
            config_generate > /dev/null 2>&1 && /etc/init.d/xkop restart > /dev/null 2>&1
        fi
    ) &

    echo $! > "$pidfile"
    return 0
}

service_prepare() {
    mkdir -p "$XKOP_RUN_DIR" "$XKOP_STATE_DIR" "$XKOP_CACHE_DIR"

    # Задачи по расписанию — первыми: это единственный путь роутера обратно
    # в рабочее состояние без человека, и отказ ниже не должен его отнять.
    cron_install

    service_check_requirements || return 1
    service_br_netfilter_disable
    service_sync_time

    # Списки нужны движку в момент загрузки конфигурации: правило geosite он
    # разворачивает сразу, и без файла отвергает конфигурацию целиком.
    lists_present || lists_update

    # Списки берутся из кэша, сеть здесь не спрашивается вовсе.
    #
    # Загрузка подсетей стояла тут же и делала старт бесконечным: у категории
    # своя минута ожидания, и на роутере, которому как раз и нужен туннель,
    # они складываются в минуты. Роутер обязан подниматься на том, что уже
    # лежит на диске — это записанный инвариант, и я его нарушил.
    #
    # Обновление уходит в фон и само перезапускает службу, только если что-то
    # действительно изменилось.
    lists_refresh_background

    userlist_update_all > /dev/null 2>&1

    subscription_update_all

    config_generate
    if config_generated_ok "$?"; then
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

# Фоновое восстановление после неудачного старта.
#
# При включении роутера WAN обычно ещё не готов: подписки не приезжают, узлов
# нет, движок либо не поднимается, либо поднимается пустым. Единственная
# починка без человека — попробовать ещё раз, и это ровно тот инвариант,
# который в podkop куплен днём отладки.
#
# Перенято оттуда целиком, вместе с тремя решениями, каждое из которых там
# исправляло настоящий отказ:
#
#   - пауза растёт от попытки к попытке и упирается в потолок: роутер в долгой
#     аварии не должен перезапускаться каждые полминуты часами;
#   - «подписка не изменилась» не означает «всё хорошо». Если подписка свежая,
#     а движок всё равно лежит, обновлять её второй раз бессмысленно — надо
#     перезапускать службу. Именно на этом мёртвый роутер оставался мёртвым;
#   - pid-файл убирается ДО перезапуска: перезапуск проходит через teardown,
#     который убивает то, на что этот файл указывает, то есть родителя самого
#     перезапуска.
XKOP_RECOVERY_PID="/var/run/xkop-recovery.pid"
XKOP_RECOVERY_ATTEMPTS="$XKOP_STATE_DIR/recovery-attempts"

recovery_running() {
    local pid
    [ -f "$XKOP_RECOVERY_PID" ] || return 1
    pid=$(cat "$XKOP_RECOVERY_PID" 2> /dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2> /dev/null
}

recovery_stop() {
    local pid
    [ -f "$XKOP_RECOVERY_PID" ] || return 0
    pid=$(cat "$XKOP_RECOVERY_PID" 2> /dev/null)
    [ -n "$pid" ] && kill "$pid" 2> /dev/null
    rm -f "$XKOP_RECOVERY_PID"
}

recovery_start() {
    local attempts wait

    if recovery_running; then
        log_info "фоновое восстановление уже работает"
        return 0
    fi
    rm -f "$XKOP_RECOVERY_PID"

    attempts=$(cat "$XKOP_RECOVERY_ATTEMPTS" 2> /dev/null)
    case "$attempts" in
        '' | *[!0-9]*) attempts=0 ;;
    esac
    mkdir -p "$XKOP_STATE_DIR"
    echo "$((attempts + 1))" > "$XKOP_RECOVERY_ATTEMPTS"

    wait=10
    while [ "$attempts" -gt 0 ] && [ "$wait" -lt 300 ]; do
        wait=$((wait * 2))
        attempts=$((attempts - 1))
    done
    [ "$wait" -gt 300 ] && wait=300

    (
        trap 'rm -f "$XKOP_RECOVERY_PID"' EXIT INT TERM

        sleep "$wait"
        delay=30

        while true; do
            # Признак успеха — появившийся пул, а не код возврата обновления:
            # обновление обходит подписки по их расписанию и завершается
            # нулём, даже когда ни одна не ответила. Условие на нём было бы
            # пустым, и восстановление вырождалось бы в один перезапуск.
            subscription_update_all force > /dev/null 2>&1
            pool=$(subscription_pool_all 2> /dev/null | jq 'length' 2> /dev/null)
            case "$pool" in
                '' | *[!0-9]*) pool=0 ;;
            esac

            if [ "$pool" -gt 0 ]; then
                if engine_answers; then
                    log_info "восстановление удалось, движок отвечает"
                    rm -f "$XKOP_RECOVERY_PID" "$XKOP_RECOVERY_ATTEMPTS"
                    exit 0
                fi

                # Узлы приехали — их надо донести до движка. Обновление само
                # ничего не перезапускает, и без этого пул есть, а движок
                # работает на прежней, пустой конфигурации.
                log_info "подписки приехали, перезапускаю службу с новой конфигурацией"
                config_generate > /dev/null 2>&1
                rm -f "$XKOP_RECOVERY_PID"
                /etc/init.d/xkop restart > /dev/null 2>&1
                exit 0
            fi

            log_warn "подписки ещё недоступны, повтор через ${delay} с"
            sleep "$delay"
            [ "$delay" -lt 300 ] && delay=$((delay * 2))
            [ "$delay" -gt 300 ] && delay=300
        done
    ) &

    echo $! > "$XKOP_RECOVERY_PID"
    log_warn "взведено фоновое восстановление, первая попытка через ${wait} с"
}

# Вызывается из start_service_done: старт вернул ноль и движок поднялся —
# разные утверждения, и различать их тут и есть работа.
service_started_check() {
    if engine_wait 20; then
        rm -f "$XKOP_RECOVERY_ATTEMPTS"

        # Узел закрепляется сразу, а не через пять минут по расписанию.
        #
        # Пока закрепления нет, балансировщик выбирает заново на КАЖДОЕ
        # соединение, и несколько одновременных потоков расходятся по разным
        # узлам: 183 мс на одном, 618 на другом. Замер скорости на этом
        # спотыкается ещё до начала — он опрашивает канал короткими запросами
        # и видит разброс, которого в канале нет. В sing-box то же самое даёт
        # urltest, который держится одного узла.
        #
        # В фоне: закрепление спрашивает движок, а start_service_done не место
        # для ожидания.
        (nodes_keep > /dev/null 2>&1 &)

        # И то, что не скачалось, пока движка ещё не было.
        (subscription_retry_failed > /dev/null 2>&1 &)
        return 0
    fi

    log_error "движок не ответил после запуска"
    recovery_start
    return 1
}

# Остановка.
#
# При перезапуске сеть не разбирается: dnsmasq не возвращается к прежним
# резолверам и правила nft не снимаются. Разбирать их незачем — через секунду
# они будут выставлены снова, — а пока разобраны, у клиентов нет ни
# маршрутизации, ни имён. В журнале это видно как «правила сняты ... dnsmasq
# возвращён ... dnsmasq переключён» на каждый чих, и ровно в эту дыру попадал
# идущий замер скорости.
#
# nft_apply и без того меняет набор целиком и атомарно, а dnsmasq при
# совпадающем состоянии ничего не делает — то есть мягкая остановка ничего
# не оставляет в неопределённом виде.
service_teardown() {
    recovery_stop

    if [ "${XKOP_RESTARTING:-0}" = "1" ]; then
        log_info "перезапуск: сеть не разбираю"
        return 0
    fi

    # Задачи по расписанию снимаются здесь и только здесь. Остановленный xkop,
    # который продолжает по будильнику обновлять подписки и перегенерировать
    # конфигурацию, — это остановленный только на словах.
    cron_remove

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
        # Только код 0 — «поставлена новая». Двойка означает «прежняя годится»,
        # и перезапускаться на ней значит рвать соединения ни за чем.
        config_generate
        [ "$?" -eq 0 ] && restart=1
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

# Количество узлов и признак ответа можно передать снаружи: обзор их уже знает,
# и повторять сборку пула и запрос к эндпоинту незачем.
service_status_json() {
    local nodes="${1:-}" answering_in="${2:-}"
    local enabled=0 running=0 answering=0

    [ -x /etc/rc.d/S99xkop ] && enabled=1
    engine_process_running && running=1

    if [ -n "$answering_in" ]; then
        answering="$answering_in"
    else
        engine_answers && answering=1
    fi

    if [ -z "$nodes" ]; then
        nodes=$(subscription_pool_all | jq 'length' 2> /dev/null)
    fi
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
