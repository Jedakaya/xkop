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

    jq -nc --arg selected "$selected" --arg override "$override" \
        '{
            ok: true,
            balancer: "pool",
            selection: (if $override != "" then "manual" else "auto" end),
            selected: (if $selected == "" then null else $selected end),
            override: (if $override == "" then null else $override end)
        }'
}

# Everything about the pool in one answer: what the subscription gave, what the
# observatory thinks of it, and which one is being used right now.
nodes_json() {
    local pool stats selection

    pool=$(subscription_pool_all)
    stats=$(cmd_stats 2> /dev/null)
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
