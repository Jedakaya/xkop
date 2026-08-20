#!/bin/sh
# shellcheck shell=ash
# Nodes: which one the balancer is on, and pinning it to one.
#
# The engine answers both questions itself through its control interface. That
# matters: the balancer picks per connection by its own strategy, and any guess
# we made here would be an opinion presented as a fact - exactly the habit this
# project is written against.
#
# Automatic selection is the default and the balancer decides. A manual choice
# is an override that stays until it is removed, and the interface has to show
# that it is on: a node pinned by hand does not move when it dies, and someone
# has to know why the router stopped switching.

XKOP_BALANCER_TAG='pool'

nodes_api_address() {
    printf '127.0.0.1:%s' "${XKOP_API_PORT_DEFAULT:-11112}"
}

# Flags go before the positional arguments and not after: the engine parses
# them with Go's flag package, which stops at the first non-flag word. With the
# address at the end it is silently ignored and the call goes to the default
# port, where nothing is listening.
nodes_api() {
    local engine command="$1"
    shift
    engine=$(config_engine_bin)
    command -v "$engine" > /dev/null 2>&1 || return 2
    "$engine" api "$command" --server="$(nodes_api_address)" -t 3 "$@" 2> /dev/null
}

# "xray api bi" prints a table: a header line ending in a colon, then rows of
# an index and a value. Only two blocks of it are of any use to us.
nodes_balancer_field() {
    local output="$1" header="$2"

    printf '%s\n' "$output" \
        | awk -v header="$header" '
            index($0, header) { grab = 1; next }
            grab && /:[[:space:]]*$/ { grab = 0 }
            grab && NF >= 2 { $1 = ""; sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); if ($0 != "") { print; exit } }
        '
}

nodes_selection_json() {
    local output selected override

    output=$(nodes_api bi "$XKOP_BALANCER_TAG")
    if [ -z "$output" ]; then
        jq -nc '{ok: false, error: "engine_unreachable",
                 detail: {balancer: "pool"}}'
        return 0
    fi

    override=$(nodes_balancer_field "$output" "Selecting Override")
    selected=$(nodes_balancer_field "$output" "Selects")

    # Закрепление сильнее стратегии, и показывать надо именно его.
    #
    # "Selects" в ответе движка — это выбор СТРАТЕГИИ, а не то, куда идёт
    # трафик. При закреплении он остаётся прежним, хотя соединения уже уходят
    # на закреплённый узел: проверено на живом движке — в журнале доступа
    # стоит закреплённый узел, а "Selects" показывает другой. Мы показывали
    # "Selects", и человек справедливо решал, что его выбор игнорируют.
    jq -nc --arg selected "$selected" --arg override "$override" \
        '{
            ok: true,
            balancer: "pool",
            selection: (if $override != "" then "manual" else "auto" end),
            selected: (if $override != "" then $override
                       elif $selected == "" then null
                       else $selected end),
            strategy_would_pick: (if $selected == "" then null else $selected end),
            override: (if $override == "" then null else $override end)
        }'
}

# Everything about the pool in one answer: what the subscription gave, what the
# observatory thinks of it, and which one is being used right now.
# Готовые метрики и пул можно передать снаружи.
#
# Обзор собирает всё одной командой, и без этого метрики забирались дважды,
# а пул собирался дважды: nodes_json делал свой запрос, а вызывающий - свой.
# На роутере это секунды, и браузер успевал оборвать запрос раньше ответа -
# ровно та ошибка "XHR request aborted by browser", которую видел пользователь.
nodes_json() {
    local pool="${1:-}" stats="${2:-}" selection

    [ -n "$pool" ] || pool=$(subscription_pool_all)
    [ -n "$stats" ] || stats=$(cmd_stats 2> /dev/null)
    selection=$(nodes_selection_json)

    jq -nc \
        --argjson pool "$pool" \
        --argjson stats "${stats:-null}" \
        --argjson selection "$selection" \
        '
        ($stats.observatory.nodes // []) as $observed
        | {
            ok: true,
            selection: $selection.selection,
            selected: $selection.selected,
            override: $selection.override,
            nodes: [
                $pool[] | . as $node
                | ($observed[] | select(.tag == $node.tag)) // {state: "unobserved", delay_ms: null}
                | {
                    tag: $node.tag,
                    protocol: $node.protocol,
                    subscription: $node.subscription,
                    state: .state,
                    delay_ms: .delay_ms,
                    selected: ($node.tag == $selection.selected)
                }
            ],
            alive: [ $observed[] | select(.state == "alive") ] | length,
            total: ($pool | length)
        }'
}

# Manual choice, or back to automatic. The engine is told; nothing is written
# down here, because a pin that survives a restart of the engine but not of the
# router would be a state nobody can explain.
nodes_select() {
    local tag="$1"

    if [ "$tag" = "auto" ] || [ -z "$tag" ]; then
        nodes_api bo -b "$XKOP_BALANCER_TAG" -r > /dev/null
        case "$?" in
            0) jq -nc '{ok: true, selection: "auto", selected: null}' ;;
            2) jq -nc '{ok: false, error: "engine_not_found"}' ;;
            *) jq -nc '{ok: false, error: "override_not_removed"}' ;;
        esac
        return 0
    fi

    if ! subscription_pool_all | jq -e --arg tag "$tag" 'any(.[]; .tag == $tag)' > /dev/null 2>&1; then
        jq -nc --arg tag "$tag" \
            '{ok: false, error: "unknown_node", detail: {tag: $tag}}'
        return 0
    fi

    nodes_api bo -b "$XKOP_BALANCER_TAG" "$tag" > /dev/null
    case "$?" in
        0) jq -nc --arg tag "$tag" '{ok: true, selection: "manual", selected: $tag}' ;;
        2) jq -nc '{ok: false, error: "engine_not_found"}' ;;
        *) jq -nc --arg tag "$tag" '{ok: false, error: "override_failed", detail: {tag: $tag}}' ;;
    esac
}

# Удержание выбранного узла.
#
# Ни одна стратегия движка не помнит предыдущий выбор: и leastPing,
# и leastLoad каждый раз считают заново, поэтому два узла с близкой задержкой
# меняются местами от шума измерения. В sing-box это лечится полем tolerance
# у urltest - «не переключайся, если выигрыш меньше стольких-то миллисекунд»,
# - и подтверждено на клиентах podkop. У Xray такого поля нет ни в одной
# стратегии, проверено на самом движке.
#
# Поэтому удержание делаем сами, поверх того же закрепления, которым узел
# закрепляет человек. Правило ровно одно и объяснимое: держимся текущего, пока
# он жив и не проигрывает лучшему больше допуска. Умер или стал заметно хуже -
# переходим, и в журнале сказано, почему.
#
# Закрепление, сделанное человеком, не трогается никогда. Отличаем своё от
# чужого по метке: в ней записан тег, который закрепили мы.
XKOP_AUTOPIN_MARKER_NAME='autopin'

nodes_autopin_marker() {
    printf '%s/%s' "$XKOP_RUN_DIR" "$XKOP_AUTOPIN_MARKER_NAME"
}

nodes_switch_tolerance() {
    local value
    value=$(config_uci_get settings switch_tolerance_ms 2> /dev/null)
    case "$value" in
        '' | *[!0-9]*) value=200 ;;
    esac
    printf '%s' "$value"
}

nodes_max_delay() {
    local value
    value=$(config_uci_get settings max_delay_ms 2> /dev/null)
    case "$value" in
        '' | *[!0-9]*) value=0 ;;
    esac
    printf '%s' "$value"
}

nodes_keep() {
    local selection override current marker mine tolerance max_delay
    local stats alive best best_delay current_delay reason=""

    selection=$(nodes_selection_json)
    if [ "$(printf '%s' "$selection" | jq -r '.ok')" != "true" ]; then
        printf '%s' "$selection"
        return 0
    fi

    override=$(printf '%s' "$selection" | jq -r '.override // ""')
    marker=$(nodes_autopin_marker)
    mine=$(cat "$marker" 2> /dev/null)

    # Чужое закрепление - решение человека, и оно не обсуждается.
    if [ -n "$override" ] && [ "$override" != "$mine" ]; then
        jq -nc --arg tag "$override" \
            '{ok: true, result: "manual", selected: $tag,
              reason: "закреплено вручную, автоматика не вмешивается"}'
        return 0
    fi

    stats=$(cmd_stats 2> /dev/null)
    alive=$(printf '%s' "$stats" \
        | jq -c '[.observatory.nodes[]? | select(.state == "alive" and .delay_ms != null)]' 2> /dev/null)
    [ -n "$alive" ] || alive='[]'

    if [ "$(printf '%s' "$alive" | jq 'length')" = "0" ]; then
        jq -nc '{ok: true, result: "no_data",
                 reason: "живых узлов с измеренной задержкой нет, выбор не трогаем"}'
        return 0
    fi

    best=$(printf '%s' "$alive" | jq -r 'min_by(.delay_ms) | .tag')
    best_delay=$(printf '%s' "$alive" | jq -r 'min_by(.delay_ms) | .delay_ms')

    current="$override"
    [ -n "$current" ] || current=$(printf '%s' "$selection" | jq -r '.selected // ""')

    current_delay=$(printf '%s' "$alive" | jq -r --arg tag "$current" \
        '(map(select(.tag == $tag)) | first | .delay_ms) // empty')

    tolerance=$(nodes_switch_tolerance)
    max_delay=$(nodes_max_delay)

    if [ -z "$current" ] || [ -z "$current_delay" ]; then
        reason="текущий узел не отвечает"
    elif [ "$max_delay" -gt 0 ] && [ "${current_delay%.*}" -gt "$max_delay" ]; then
        reason="задержка ${current_delay} мс выше порога ${max_delay} мс"
    elif [ "$((${current_delay%.*} - ${best_delay%.*}))" -gt "$tolerance" ]; then
        reason="проигрывает лучшему $((${current_delay%.*} - ${best_delay%.*})) мс при допуске ${tolerance} мс"
    fi

    if [ -z "$reason" ]; then
        # Держимся текущего. Закрепляем его, если ещё не закреплён: иначе
        # балансировщик продолжит выбирать заново на каждом соединении.
        if [ -z "$override" ]; then
            nodes_api bo -b "$XKOP_BALANCER_TAG" "$current" > /dev/null 2>&1 \
                && printf '%s' "$current" > "$marker"
        fi
        jq -nc --arg tag "$current" --argjson delay "${current_delay:-0}" \
            '{ok: true, result: "kept", selected: $tag, delay_ms: $delay}'
        return 0
    fi

    if [ "$best" = "$current" ]; then
        jq -nc --arg tag "$current" --arg reason "$reason" \
            '{ok: true, result: "kept", selected: $tag,
              reason: ("лучше некуда: " + $reason)}'
        return 0
    fi

    if nodes_api bo -b "$XKOP_BALANCER_TAG" "$best" > /dev/null 2>&1; then
        printf '%s' "$best" > "$marker"
        log_info "узел сменён на $best: $reason"
        jq -nc --arg tag "$best" --arg from "$current" --arg reason "$reason" \
            --argjson delay "${best_delay:-0}" \
            '{ok: true, result: "switched", selected: $tag, previous: $from,
              delay_ms: $delay, reason: $reason}'
    else
        jq -nc --arg tag "$best" '{ok: false, error: "override_failed", detail: {tag: $tag}}'
    fi
}
