#!/bin/sh
# shellcheck shell=ash
# Diagnostics.
#
# One rule governs everything here: never report green where nothing was
# checked, and never name a cause that was not established. An external service
# being unreachable says nothing about the mechanism it was supposed to test -
# that is "проверить не удалось", not "сломано". In podkop this was fixed three
# times, and each time the interface had already told someone a lie.
#
# Every check therefore has three outcomes, not two: passed, failed, and could
# not be performed.

diag_router_info() {
    local model="" release="" arch="" manager="unknown"

    [ -f /tmp/sysinfo/model ] && model=$(cat /tmp/sysinfo/model 2> /dev/null)
    if [ -r /etc/os-release ]; then
        release=$(. /etc/os-release 2> /dev/null && echo "${PRETTY_NAME:-}")
        arch=$(. /etc/os-release 2> /dev/null && echo "${OPENWRT_ARCH:-}")
    fi
    [ -n "$arch" ] || arch=$(uname -m 2> /dev/null)
    command -v apk > /dev/null 2>&1 && manager="apk"
    command -v opkg > /dev/null 2>&1 && manager="opkg"

    jq -nc \
        --arg model "${model:-неизвестно}" \
        --arg release "${release:-неизвестно}" \
        --arg arch "${arch:-неизвестно}" \
        --arg manager "$manager" \
        --arg kernel "$(uname -r 2> /dev/null)" \
        '{model: $model, release: $release, arch: $arch, package_manager: $manager, kernel: $kernel}'
}

diag_storage() {
    local overlay_kb free_kb mem_total mem_free

    overlay_kb=$(df -k /overlay 2> /dev/null | awk 'NR==2 {print $2}')
    free_kb=$(df -k /overlay 2> /dev/null | awk 'NR==2 {print $4}')
    [ -n "$free_kb" ] || free_kb=$(df -k / 2> /dev/null | awk 'NR==2 {print $4}')
    mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2> /dev/null)
    mem_free=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2> /dev/null)

    jq -nc \
        --argjson overlay_kb "${overlay_kb:-0}" --argjson free_kb "${free_kb:-0}" \
        --argjson mem_total "${mem_total:-0}" --argjson mem_free "${mem_free:-0}" \
        '{flash_total_kb: $overlay_kb, flash_free_kb: $free_kb,
          memory_total_kb: $mem_total, memory_free_kb: $mem_free}'
}

# Uptime in words. /proc/uptime is seconds with a fraction, and busybox has no
# tool that turns it into something a person reads.
diag_uptime() {
    local secs days hours mins

    secs=$(awk '{printf "%d", $1}' /proc/uptime 2> /dev/null)
    [ -n "$secs" ] || return 0

    days=$((secs / 86400))
    hours=$(((secs % 86400) / 3600))
    mins=$(((secs % 3600) / 60))

    if [ "$days" -gt 0 ]; then
        printf '%dд %dч' "$days" "$hours"
    elif [ "$hours" -gt 0 ]; then
        printf '%dч %dм' "$hours" "$mins"
    else
        printf '%dм' "$mins"
    fi
}

diag_system_json() {
    jq -nc \
        --argjson router "$(diag_router_info)" \
        --argjson storage "$(diag_storage)" \
        --arg version "$XKOP_VERSION" \
        '{ok: true, xkop_version: $version, router: $router, storage: $storage}'
}

# The rules are ours, so the answer is factual: is the table there, and has
# anything actually gone through it. A table with zero packets on a router that
# has been up for a day is a different problem from a missing table.
diag_nft_json() {
    local present=0 packets=0 dump

    if nft_present; then
        present=1
        dump=$(nft list table inet "$XKOP_NFT_TABLE" 2> /dev/null)
        packets=$(printf '%s' "$dump" | sed -n 's/.*counter packets \([0-9]*\).*/\1/p' \
            | awk '{sum += $1} END {print sum + 0}')
    fi

    jq -nc \
        --argjson present "$present" --argjson packets "${packets:-0}" \
        --arg table "$XKOP_NFT_TABLE" \
        '{
            ok: true,
            table: $table,
            rules_present: ($present == 1),
            packets_seen: $packets,
            state: (
                if ($present == 0) then "правил нет"
                elif $packets == 0 then "правила есть, трафик через них ещё не шёл"
                else "правила работают"
                end
            )
        }'
}

diag_logs_json() {
    local lines="${1:-50}" log=""

    if command -v logread > /dev/null 2>&1; then
        log=$(logread -e xkop 2> /dev/null | tail -n "$lines")
        [ -n "$log" ] || log=$(logread 2> /dev/null | grep -i 'xkop\|xray' | tail -n "$lines")
    fi

    if [ -z "$log" ]; then
        jq -nc '{ok: false, error: "no_log", detail: {source: "logread"}, lines: []}'
        return 0
    fi

    printf '%s' "$log" | jq -R -s -c '{ok: true, lines: (split("\n") | map(select(. != "")))}'
}

# Does the configured resolver answer at all. Deliberately says nothing about
# whether the answer is honest - that is the Канарейка's question, and mixing
# the two produces a verdict nobody can act on.
diag_dns_json() {
    local server answered=0 address="" started ended took=0

    server=$(config_uci_get settings dns_server)
    [ -n "$server" ] || server="1.1.1.1"

    if command -v nslookup > /dev/null 2>&1; then
        started=$(date +%s)
        address=$(canary_addresses "openwrt.org" | head -n 1)
        ended=$(date +%s)
        took=$((ended - started))
        [ -n "$address" ] && answered=1
    fi

    jq -nc \
        --arg server "$server" --arg address "$address" \
        --argjson answered "$answered" --argjson took "$took" \
        '{
            ok: true,
            server: $server,
            answered: ($answered == 1),
            address: (if $address == "" then null else $address end),
            took_seconds: $took,
            state: (if $answered == 1 then "резолвер отвечает" else "резолвер не ответил" end)
        }'
}

# FakeIP is proven locally, by asking our own listener and looking at what it
# hands back. No external service is involved: on a network where the test host
# is blocked by SNI, an external check reports a broken tunnel that works.
diag_fakeip_json() {
    local mode probe answer in_range=0 checked=1

    mode=$(config_uci_get settings dns_mode)
    [ -n "$mode" ] || mode="off"

    if [ "$mode" != "fakeip" ]; then
        jq -nc '{ok: true, mode: "off", checked: false,
                 state: "режим fakeip выключен, проверять нечего"}'
        return 0
    fi

    probe=$(subscription_pool_all > /dev/null 2>&1; echo "openwrt.org")
    answer=$(canary_addresses "$probe" "$XKOP_DNS_INBOUND_ADDRESS" | head -n 1)

    if [ -z "$answer" ]; then
        checked=0
    else
        case "$answer" in
            198.1[89].*) in_range=1 ;;
        esac
    fi

    jq -nc \
        --arg answer "$answer" --arg probe "$probe" \
        --argjson in_range "$in_range" --argjson checked "$checked" \
        '{
            ok: true,
            mode: "fakeip",
            checked: ($checked == 1),
            probe: $probe,
            answer: (if $answer == "" then null else $answer end),
            fake: ($in_range == 1),
            state: (
                if ($checked == 0) then "наш резолвер не ответил, проверить не удалось"
                elif ($in_range == 1) then "поддельный адрес выдаётся"
                else "адрес настоящий: имя не маршрутизируется или подделка не работает"
                end
            )
        }'
}

# One answer for the whole router. The summary line says what is wrong rather
# than showing five green ticks for the user to interpret.
diag_global_json() {
    jq -nc \
        --argjson system "$(diag_system_json)" \
        --argjson status "$(service_status_json)" \
        --argjson engine "$(cmd_check_engine)" \
        --argjson nft "$(diag_nft_json)" \
        --argjson dns "$(diag_dns_json)" \
        --argjson fakeip "$(diag_fakeip_json)" \
        --argjson subscriptions "$(cmd_subscriptions)" \
        --argjson lists "$(lists_present && echo true || echo false)" \
        '
        {
            ok: true,
            system: $system,
            service: $status,
            engine: $engine,
            nft: $nft,
            dns: $dns,
            fakeip: $fakeip,
            subscriptions: $subscriptions,
            lists_present: $lists
        }
        | . + {
            summary: (
                if ($engine.engine_installed | not) then "движок не установлен"
                elif ($status.engine.running | not) then "движок не запущен"
                elif ($status.engine.answering | not) then "движок запущен, но не отвечает"
                elif ($nft.rules_present | not) then "правила nft не применены"
                elif ([$subscriptions[] | select(.state == "ready")] | length) == 0
                     and ($subscriptions | length) > 0 then
                    "подписки не готовы: " + ([$subscriptions[] | .reason // .state] | join(", "))
                elif ($status.nodes == 0) then "узлов нет, трафик идёт напрямую"
                elif ($lists | not) then "списков доменов нет, правила по спискам не сработают"
                else "работает"
                end
            )
        }'
}

# Everything the overview shows, in one process.
#
# The dashboard used to run five commands per render, and two of them asked
# the network: the DNS and FakeIP checks each wait for a resolver, and the
# canary probes on top of that. Seconds of waiting for a page whose job is to
# say what is happening right now.
#
# What asks the network stays out of here on purpose. Live probes belong to a
# button the user presses, not to opening a page.
diag_dashboard_json() {
    jq -nc \
        --argjson status "$(service_status_json)" \
        --argjson engine "$(cmd_check_engine)" \
        --argjson nft "$(diag_nft_json)" \
        --argjson subscriptions "$(cmd_subscriptions)" \
        --argjson lists "$(lists_present && echo true || echo false)" \
        --argjson stats "$(cmd_stats)" \
        --argjson nodes "$(nodes_json)" \
        --argjson canary "$(canary_cached_json)" \
        --argjson system "$(diag_system_json)" \
        --arg uptime "$(diag_uptime)" \
        --arg version "${XKOP_VERSION:-}" \
        '
        {
            ok: true,
            version: $version,
            system: ($system + {uptime: $uptime}),
            service: $status,
            engine: $engine,
            nft: $nft,
            subscriptions: $subscriptions,
            lists_present: $lists,
            stats: $stats,
            nodes: $nodes,
            canary: $canary
        }
        | . + {
            summary: (
                if ($engine.engine_installed | not) then "движок не установлен"
                elif ($status.engine.running | not) then "движок не запущен"
                elif ($status.engine.answering | not) then "движок запущен, но не отвечает"
                elif ($nft.rules_present | not) then "правила nft не применены"
                elif ([$subscriptions[] | select(.state == "ready")] | length) == 0
                     and ($subscriptions | length) > 0 then
                    "подписки не готовы: " + ([$subscriptions[] | .reason // .state] | join(", "))
                elif ($status.nodes == 0) then "узлов нет, трафик идёт напрямую"
                elif ($lists | not) then "списков доменов нет, правила по спискам не сработают"
                else "работает"
                end
            )
        }'
}
