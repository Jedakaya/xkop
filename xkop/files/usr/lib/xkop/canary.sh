#!/bin/sh
# shellcheck shell=ash
# Канарейка - detection of DNS interception.
#
# The name is literal: a bird in a mine does not fight the gas, it reports that
# the air is not breathable. This code only ever reports. What to do about it -
# reject the answer, switch resolvers, tell the user - is decided above, and
# mixing the two is what made the same thing in podkop impossible to debug.
#
# How it finds out:
#
#   1. It asks for a name that cannot exist. Anything under .invalid is
#      guaranteed by RFC 2606 never to resolve, and a random label in front of
#      it rules out a cached answer. An honest resolver says NXDOMAIN. An
#      interceptor answers with its own address - and now we know that address.
#
#   2. It sends a query to an address where no resolver can be: 192.0.2.1 from
#      the documentation range of RFC 5737. Nothing there can answer. If
#      something does, port 53 is being intercepted transparently, and whatever
#      answered is the interceptor.
#
# The learned addresses go into unexpectedIPs of the engine's DNS servers, and
# from that moment any answer containing one is rejected on arrival - whichever
# resolver it came from.

XKOP_CANARY_SUFFIX='.invalid'
XKOP_CANARY_TESTNET='192.0.2.1'

canary_random_name() {
    local salt
    salt=$(head -c 8 /dev/urandom 2> /dev/null | md5sum | cut -c1-10)
    [ -n "$salt" ] || salt=$(date +%s)
    printf 'xkop-%s%s' "$salt" "$XKOP_CANARY_SUFFIX"
}

# Addresses from the ANSWER of a query, one per line. Two spellings of the same
# question, because a router has one of two tools and never both.
canary_addresses() {
    local name="$1" server="${2:-}"

    if command -v dig > /dev/null 2>&1; then
        if [ -n "$server" ]; then
            dig +short +time=3 +tries=1 A "$name" "@$server" 2> /dev/null
        else
            dig +short +time=3 +tries=1 A "$name" 2> /dev/null
        fi | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
        return 0
    fi

    # busybox nslookup prints the server it asked as "Address: 1.2.3.4:53" and
    # the answers without a port. That difference is the only reliable way to
    # tell the two apart in its output.
    nslookup "$name" $server 2> /dev/null \
        | sed -n 's/^Address: *\([0-9.]*\)$/\1/p' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

# Resolvers the router itself was handed. A provider intercepting DNS usually
# does it on the very servers it handed out.
canary_upstreams() {
    local file='/tmp/resolv.conf.d/resolv.conf.auto'
    [ -f "$file" ] || file='/etc/resolv.conf'
    [ -f "$file" ] || return 0
    sed -n 's/^nameserver *\([0-9.]*\)$/\1/p' "$file" | grep -v '^127\.' | head -n 3
}

# One full round. Prints the addresses learned, if any.
canary_detect() {
    local name server found=""

    name=$(canary_random_name)

    # A name that cannot exist, asked of every resolver we were given.
    for server in "" $(canary_upstreams); do
        found="$found $(canary_addresses "$name" "$server" | tr '\n' ' ')"
    done

    # A resolver that cannot exist. Any answer at all is the interception
    # itself answering.
    found="$found $(canary_addresses "openwrt.org" "$XKOP_CANARY_TESTNET" | tr '\n' ' ')"

    printf '%s\n' $found | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u
}

canary_learned() {
    subscription_config_list settings canary_learned_ip 2> /dev/null | sort -u
}

canary_store() {
    local address
    uci -q delete "$XKOP_CONFIG.settings.canary_learned_ip" 2> /dev/null
    for address in $1; do
        uci -q add_list "$XKOP_CONFIG.settings.canary_learned_ip=$address"
    done
    uci -q commit "$XKOP_CONFIG"
}

# Detect, remember, and say what happened. The verdict is deliberately three
# valued: a probe that could not be made is not evidence of a clean network,
# and reporting it as such is the exact lie this project keeps refusing to tell.
# Probes once, remembers what changed, and writes the result down. Returns 10
# when the learned set changed - the caller then knows the engine is holding a
# configuration that no longer matches what we know about this network.
canary_run() {
    local detected learned state="clean" changed=0 enabled
    local out="$XKOP_RUN_DIR/canary.json"
    mkdir -p "$XKOP_RUN_DIR"

    enabled=$(config_uci_get settings canary_enabled)
    [ -n "$enabled" ] || enabled=1

    if [ "$enabled" = "0" ]; then
        jq -nc '{enabled: false, state: "disabled", hijacked: false,
                 detected: [], learned: [], changed: false}' > "$out"
        return 0
    fi

    if ! command -v nslookup > /dev/null 2>&1 && ! command -v dig > /dev/null 2>&1; then
        # A probe that could not be made is not evidence of a clean network.
        log_warn "нечем спросить DNS, Канарейка не проверяла"
        jq -nc '{enabled: true, state: "unknown", hijacked: false,
                 detected: [], learned: [], changed: false}' > "$out"
        return 0
    fi

    detected=$(canary_detect | tr '\n' ' ' | sed 's/ *$//')
    learned=$(canary_learned | tr '\n' ' ' | sed 's/ *$//')
    [ -n "$detected" ] && state="hijacked"

    if [ "$detected" != "$learned" ]; then
        changed=1
        canary_store "$detected"
        if [ -n "$detected" ]; then
            log_warn "Канарейка: провайдер подменяет DNS, выучены адреса: $detected"
        else
            # Interception can be lifted, and then the address has to be
            # forgotten - otherwise an honest answer keeps being thrown away
            # for the rest of the router's life.
            log_info "Канарейка: подмена больше не наблюдается, выученные адреса забыты"
        fi
    fi

    jq -nc \
        --arg state "$state" \
        --argjson changed "$changed" \
        --argjson detected "$(printf '%s' "$detected" | tr ' ' '\n' | jq -R -s -c 'split("\n") | map(select(. != ""))')" \
        --argjson learned "$(canary_learned | jq -R -s -c 'split("\n") | map(select(. != ""))')" \
        '{
            enabled: true,
            state: $state,
            hijacked: ($state == "hijacked"),
            detected: $detected,
            learned: $learned,
            changed: ($changed == 1)
        }' > "$out"

    [ "$changed" -eq 1 ] && return 10
    return 0
}

# Last known state, without asking the network. The dashboard must never
# probe: probing costs seconds on every page load, and canary_state_json
# restarts the service when the learned set changes - a page view has no
# business restarting anything.
canary_cached_json() {
    local out="$XKOP_RUN_DIR/canary.json"

    if [ -s "$out" ]; then
        jq -c '{ok: true, cached: true} + .' "$out"
    else
        jq -nc '{ok: true, cached: true, enabled: true, state: "unknown",
                 hijacked: false, detected: [], learned: [], changed: false}'
    fi
}

canary_state_json() {
    local out="$XKOP_RUN_DIR/canary.json"

    canary_run
    if [ -s "$out" ]; then
        jq -c '{ok: true} + . + {probes: {nonexistent_name: "*.invalid",
                                          unreachable_resolver: "192.0.2.1"}}' "$out"
    else
        jq -nc '{ok: false, error: "canary_failed"}'
    fi
}
