#!/bin/sh
# shellcheck shell=ash
# stats - engine metrics, normalized.
#
# Reads the Xray metrics endpoint and hands back the xkop stats contract, so
# that neither the client panel nor LuCI ever learns the shape of Xray output
# or the address of its endpoint. See docs/cli-contract.md.
#
# The command always prints a complete envelope and always exits 0 once it has
# run: a zero exit code means "the command worked", not "everything is fine".
# What happened is in the fields.

metrics_port() {
    local port
    port=$(uci -q get "$XKOP_CONFIG.settings.metrics_port" 2> /dev/null)
    [ -n "$port" ] || port="$XKOP_METRICS_PORT_DEFAULT"
    printf '%s' "$port"
}

engine_is_running() {
    pgrep -x "$XKOP_ENGINE_BIN" > /dev/null 2>&1 && return 0
    pgrep -f "$XKOP_ENGINE_BIN" > /dev/null 2>&1
}

# Failure envelope. Same key set as the success one, so a consumer never has to
# branch on presence of fields. The reason is a code, and the detail carries the
# facts we actually observed - no prose, and nothing we did not establish.
stats_failure() {
    local error="$1" address="$2" http_code="$3" curl_exit="$4"

    jq -n \
        --arg error "$error" \
        --arg address "$address" \
        --arg http_code "$http_code" \
        --arg curl_exit "$curl_exit" \
        --argjson collected_at "$(date +%s)" \
        '{
            ok: false,
            error: $error,
            detail: {
                address: $address,
                http_code: (if $http_code == "" then null else ($http_code | tonumber) end),
                curl_exit: (if $curl_exit == "" then null else ($curl_exit | tonumber) end)
            },
            source: {address: $address, collected_at: $collected_at},
            traffic: null,
            distribution: null,
            observatory: null
        }'
}

cmd_stats() {
    local address url response curl_exit http_code body output

    address="$XKOP_METRICS_HOST:$(metrics_port)"
    url="http://$address$XKOP_METRICS_PATH"

    response=$(curl -sS -m "$XKOP_METRICS_TIMEOUT" -w '\n%{http_code}' "$url" 2> /dev/null)
    curl_exit=$?

    if [ "$curl_exit" -ne 0 ]; then
        # Distinguishing these two costs one pgrep and saves the interface from
        # inventing a cause: a dead engine and a disabled metrics block look
        # identical from the socket alone.
        if engine_is_running; then
            stats_failure "metrics_unreachable" "$address" "" "$curl_exit"
        else
            stats_failure "engine_not_running" "$address" "" "$curl_exit"
        fi
        return 0
    fi

    http_code=$(echo "$response" | tail -n 1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" != "200" ]; then
        stats_failure "metrics_bad_response" "$address" "$http_code" "$curl_exit"
        return 0
    fi

    output=$(
        printf '%s' "$body" | jq \
            --arg address "$address" \
            --argjson collected_at "$(date +%s)" \
            -f "$XKOP_LIB_DIR/stats.jq" 2> /dev/null
    )

    if [ -z "$output" ]; then
        stats_failure "metrics_bad_response" "$address" "$http_code" "$curl_exit"
        return 0
    fi

    printf '%s\n' "$output"
    return 0
}
