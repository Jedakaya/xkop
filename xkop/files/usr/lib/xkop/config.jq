# Router state -> Xray configuration.
#
# Input is one object assembled by config.sh from uci and from the subscription
# pool, so that everything uncertain - what the user configured, which servers
# survived - is decided before this program runs and nothing here has to guess:
#
#   {settings: {...}, pool: [server, ...], bindings: [{profile, channel}, ...]}
#
# Output is a complete configuration. It is never installed unvalidated: the
# caller runs "xray run -test" on it first, and a configuration the engine
# rejects is a router without an engine.
#
# Field names are taken from the engine's own JSON schema (infra/conf), not
# from documentation or memory. The traps that cost the most:
#   - REALITY builds only over RAW, XHTTP and gRPC;
#   - the transports h2, http and quic are gone and raise an error;
#   - Hysteria 2 is protocol "hysteria" with "version": 2.
# The subscription parser already drops links that would violate those, so
# whatever reaches the pool here can be emitted as it came.

def service_tags: {
    direct: "direct",
    block: "block",
    dns: "dns-out",
    metrics: "metrics-out"
};

def settings: .settings;

# Only tags of real proxy nodes. The balancer and the observatory both work by
# prefix, and every full tag is a prefix of itself - listing them outright is
# the only honest way when names come from a subscription and have no shape.
def node_tags: [ .pool[]?.tag ];

def log_section:
    {loglevel: (settings.log_level // "warning")};

# Counters are what the dashboard is built on. Without the stats object the
# metrics endpoint has nothing to serve, and without the policy switches the
# counters stay at zero - both halves are needed, see docs/stats.md.
def stats_section: {};

def policy_section:
    {system: {
        statsInboundUplink: true,
        statsInboundDownlink: true,
        statsOutboundUplink: true,
        statsOutboundDownlink: true
    }};

def metrics_section:
    {tag: service_tags.metrics, listen: "127.0.0.1:\(settings.metrics_port // 11111)"};

# Traffic arrives already redirected by nftables, so the inbound only has to
# accept it. followRedirect is what makes the original destination survive the
# redirect, and sniffing is what turns it back into a domain for the rules.
def tproxy_inbound:
    {
        tag: "tproxy-in",
        protocol: "dokodemo-door",
        listen: (settings.tproxy_address // "127.0.0.1"),
        port: (settings.tproxy_port // 1608),
        settings: {network: "tcp,udp", followRedirect: true},
        streamSettings: {sockopt: {tproxy: "tproxy"}},
        sniffing: {
            enabled: true,
            destOverride: ["http", "tls", "quic"],
            routeOnly: true
        }
    };

def inbounds_section:
    [ tproxy_inbound ];

# Service outbounds, always present and always named the same: the stats
# command derives traffic roles from these tags, and a rename here silently
# moves traffic into the wrong column of the dashboard.
def service_outbounds:
    [
        {tag: service_tags.direct, protocol: "freedom", settings: {domainStrategy: "UseIP"}},
        {tag: service_tags.block, protocol: "blackhole"}
    ];

def node_outbounds:
    [ .pool[]? | .outbound ];

def outbounds_section:
    service_outbounds + node_outbounds;

# One balancer over the whole pool. The engine excludes nodes the observatory
# calls dead by itself, so quarantine is native and ours only to display.
def balancers_section:
    node_tags as $tags
    | if ($tags | length) == 0 then
        []
      else
        [{
            tag: "pool",
            selector: $tags,
            strategy: {type: (settings.strategy // "leastPing")},
            fallbackTag: service_tags.direct
        }]
      end;

# Health checks that feed both the balancer and the node states of "xkop
# stats". Durations are strings on purpose: the engine parses "30s" and refuses
# a number outright.
def observatory_section:
    node_tags as $tags
    | if ($tags | length) == 0 then
        null
      else
        {
            subjectSelector: $tags,
            pingConfig: {
                destination: (settings.probe_url // "https://connectivitycheck.gstatic.com/generate_204"),
                interval: (settings.probe_interval // "3m"),
                timeout: "5s",
                sampling: 3
            }
        }
      end;

def profile_domains($profile):
    ([ $profile.community_list[]? | "geosite:\(.)" ] + [ $profile.domain[]? ])
    | map(select(. != null and . != ""));

def profile_ips($profile):
    [ $profile.subnet[]? ] | map(select(. != null and . != ""));

# A binding becomes at most two rules: one for names, one for addresses. An
# empty profile produces nothing at all rather than a rule that matches
# everything - which is the difference between "nothing is routed" and
# "everything is".
def binding_rules($binding; $has_pool):
    ($binding.channel.type // "direct") as $type
    | (if $type == "block" then {outboundTag: service_tags.block}
       elif $type == "direct" then {outboundTag: service_tags.direct}
       elif $has_pool then {balancerTag: "pool"}
       else {outboundTag: service_tags.direct}
       end) as $target
    | profile_domains($binding.profile) as $domains
    | profile_ips($binding.profile) as $ips
    | [
        (if ($domains | length) > 0 then ({type: "field", domain: $domains} + $target) else empty end),
        (if ($ips | length) > 0 then ({type: "field", ip: $ips} + $target) else empty end)
      ];

def routing_section:
    (node_tags | length > 0) as $has_pool
    | {
        domainStrategy: "IPIfNonMatch",
        rules: (
            [
                # Anything aimed at the local network stays local. Written out
                # rather than as "geoip:private" on purpose: that spelling pulls
                # in geoip.dat, ten megabytes of flash for a list of ranges
                # everyone already knows.
                {type: "field", outboundTag: service_tags.direct, ip: [
                    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
                    "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24",
                    "192.168.0.0/16", "224.0.0.0/4", "240.0.0.0/4",
                    "::1/128", "fc00::/7", "fe80::/10"
                ]}
            ]
            + ( [ .bindings[]? ] | sort_by(.order // 100)
                | map(binding_rules(.; $has_pool)) | add // [] )
        ),
        balancers: balancers_section
    };

# Bound before the object is built: past the pipe "." is the configuration
# being assembled, not the input, and anything reading .pool there quietly
# returns nothing. Every balancer requires an observatory feature - without it
# the engine refuses the whole configuration with "not all dependencies are
# resolved", which is a dead router.
observatory_section as $observatory
| {
    log: log_section,
    stats: stats_section,
    policy: policy_section,
    metrics: metrics_section,
    inbounds: inbounds_section,
    outbounds: outbounds_section,
    routing: routing_section
}
| if $observatory != null then . + {burstObservatory: $observatory} else . end
