#!/bin/sh
# shellcheck shell=ash
# nftables and policy routing: getting client traffic into the engine.
#
# What is captured and what is not:
#
#   - only traffic arriving on the configured source interfaces;
#   - never traffic aimed at the local networks - the router, the LAN, and
#     everything else that has no business leaving;
#   - never traffic from an excluded source address.
#
# Everything else is marked and handed to the engine, and the engine decides
# per destination whether it goes through a tunnel or straight out. That is the
# whole thesis of the project: the split happens where the domain is known, not
# in the firewall, which only ever sees addresses.
#
# The whole ruleset is applied as one file. nft swaps it in atomically, so
# there is no moment where half the rules are live - which is the moment a
# router loses its network and someone has to drive to it.

nft_ruleset() {
    local interfaces="$1" excluded="$2"
    local ifname_elements="" excluded_elements=""

    for iface in $interfaces; do
        ifname_elements="$ifname_elements \"$iface\","
    done
    ifname_elements="${ifname_elements%,}"

    for address in $excluded; do
        excluded_elements="$excluded_elements $address,"
    done
    excluded_elements="${excluded_elements%,}"

    cat << EOF
table inet $XKOP_NFT_TABLE {
    set interfaces {
        type ifname
        elements = { $ifname_elements }
    }

    set local4 {
        type ipv4_addr
        flags interval
        auto-merge
        elements = {
            0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8,
            169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24,
            192.88.99.0/24, 192.168.0.0/16, 198.51.100.0/24, 203.0.113.0/24,
            224.0.0.0/4, 240.0.0.0/4
        }
    }

    set local6 {
        type ipv6_addr
        flags interval
        auto-merge
        elements = { ::1/128, fc00::/7, fe80::/10, ff00::/8 }
    }
$(if [ -n "$excluded_elements" ]; then
cat << EXCLUDED

    set excluded4 {
        type ipv4_addr
        flags interval
        auto-merge
        elements = { $excluded_elements }
    }
EXCLUDED
fi)

    chain mark {
        type filter hook prerouting priority -150; policy accept;

        iifname != @interfaces return
        ip daddr @local4 return
        ip6 daddr @local6 return
$(if [ -n "$excluded_elements" ]; then echo "        ip saddr @excluded4 return"; fi)

        meta l4proto { tcp, udp } meta mark set $XKOP_NFT_MARK counter
    }

    chain divert {
        type filter hook prerouting priority -100; policy accept;

        meta mark & $XKOP_NFT_MARK == $XKOP_NFT_MARK meta l4proto tcp \
            tproxy ip to $XKOP_TPROXY_ADDRESS:$XKOP_TPROXY_PORT counter accept
        meta mark & $XKOP_NFT_MARK == $XKOP_NFT_MARK meta l4proto udp \
            tproxy ip to $XKOP_TPROXY_ADDRESS:$XKOP_TPROXY_PORT counter accept
    }
}
EOF
}

# The marked packet has to be delivered locally instead of being routed on, and
# that is a routing decision, not a firewall one: a rule sends everything with
# our mark to a table whose only entry says "this is for us".
nft_routing_rule() {
    if ! ip route list table "$XKOP_ROUTE_TABLE" 2> /dev/null | grep -q 'local default dev lo'; then
        ip route add local 0.0.0.0/0 dev lo table "$XKOP_ROUTE_TABLE" 2> /dev/null
    fi

    if ! ip rule list | grep -q "fwmark $XKOP_NFT_MARK/$XKOP_NFT_MARK lookup $XKOP_ROUTE_TABLE"; then
        ip -4 rule add fwmark "$XKOP_NFT_MARK/$XKOP_NFT_MARK" table "$XKOP_ROUTE_TABLE" priority 106 2> /dev/null
    fi
}

nft_routing_rule_remove() {
    while ip rule list | grep -q "lookup $XKOP_ROUTE_TABLE"; do
        ip -4 rule del table "$XKOP_ROUTE_TABLE" 2> /dev/null || break
    done
    ip route flush table "$XKOP_ROUTE_TABLE" 2> /dev/null || true
}

nft_apply() {
    local interfaces excluded

    interfaces=$(subscription_config_list settings source_interface | tr '\n' ' ')
    [ -n "$(printf '%s' "$interfaces" | tr -d ' ')" ] || interfaces="br-lan"
    excluded=$(subscription_config_list settings excluded_source_ip | tr '\n' ' ')

    if ! command -v nft > /dev/null 2>&1; then
        log_error "nft не найден, правила не применены"
        return 1
    fi

    nft delete table inet "$XKOP_NFT_TABLE" 2> /dev/null || true

    if ! nft_ruleset "$interfaces" "$excluded" | nft -f - 2> "$XKOP_RUN_DIR/nft.err"; then
        log_error "правила nft отвергнуты: $(head -n 1 "$XKOP_RUN_DIR/nft.err" 2> /dev/null)"
        return 1
    fi

    nft_routing_rule
    log_info "правила nft применены, источники: $interfaces"
    return 0
}

nft_clear() {
    nft delete table inet "$XKOP_NFT_TABLE" 2> /dev/null || true
    nft_routing_rule_remove
    log_info "правила nft сняты"
}

nft_present() {
    nft list table inet "$XKOP_NFT_TABLE" > /dev/null 2>&1
}
