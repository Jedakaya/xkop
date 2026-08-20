# Normalization of the Xray metrics endpoint into the xkop stats contract.
#
# Input: the raw object served by Xray at /debug/vars.
# Args:  $address       - "host:port" the data was read from, echoed back
#        $collected_at  - unix time of the read
#
# Everything below is verified against Xray-core sources, not assumed:
#
#   app/metrics/metrics.go
#     .stats.{inbound,outbound,user}["<tag>"].{uplink,downlink} - cumulative
#     byte counters, never reset by reading; the ">>>" counter names are split
#     by the engine itself, so they never reach us.
#     .observatory is null when no observatory feature is configured.
#
#   app/observatory/config.pb.go
#     OutboundStatus is marshalled by encoding/json with snake_case tags and
#     omitempty, so a false or zero field is ABSENT, not present-and-zero.
#     Missing "alive" therefore means false, not unknown.
#
#   app/observatory/observer.go (plain observatory)
#     no health_ping; delay is milliseconds; delay is forced to 99999999 for a
#     node that failed its probe.
#
#   app/observatory/burst/burstobserver.go (burstObservatory)
#     delay is milliseconds, but every health_ping duration is NANOSECONDS -
#     they come from time.Duration cast to int64. Mixing the two units up is
#     the easiest mistake to make here.
#     alive is computed as all != fail, so a node that has not been probed yet
#     reports alive=false with all=0. That is the ten-minute window of a freshly
#     added outbound, and it must not be shown as dead.

def service_tags: ["dns-out", "metrics-out", "api"];

# Reserved outbound tags of a generated xkop configuration. Everything else is
# a proxy node.
def role($tag):
    if $tag == "direct" then "direct"
    elif $tag == "block" then "blocked"
    elif service_tags | index($tag) then "service"
    else "proxy"
    end;

def ns_to_ms($ns): (($ns / 100000) | round) / 10;

# Sentinel written by the plain observatory for a node that failed its probe.
def dead_delay: 99999999;

def counters:
    (. // {})
    | with_entries(
        .value = {
            uplink: (.value.uplink // 0),
            downlink: (.value.downlink // 0),
            total: ((.value.uplink // 0) + (.value.downlink // 0))
        }
    );

def sum_counters:
    reduce (to_entries[]) as $e (
        {uplink: 0, downlink: 0, total: 0};
        {
            uplink: (.uplink + $e.value.uplink),
            downlink: (.downlink + $e.value.downlink),
            total: (.total + $e.value.total)
        }
    );

# Bytes per role plus its share of the total. This is the number the dashboard
# is built around: it answers whether traffic is being distributed at all.
def distribution:
    reduce (to_entries[]) as $e (
        {direct: 0, proxy: 0, blocked: 0, service: 0};
        .[role($e.key)] += $e.value.total
    )
    | (.direct + .proxy + .blocked + .service) as $sum
    | with_entries(
        .value = {
            bytes: .value,
            share: (if $sum == 0 then 0 else ((.value * 10000 / $sum) | round) / 10000 end)
        }
    );

def node_from_status($tag; $s):
    ($s.health_ping) as $hp
    | ($s.alive // false) as $alive
    | if $hp != null then
        ($hp.all // 0) as $all
        | ($hp.fail // 0) as $fail
        | ($all - $fail) as $ok
        | {
            tag: $tag,
            state: (if $all == 0 then "pending" elif $alive then "alive" else "dead" end),
            delay_ms: (if $all == 0 or ($alive | not) then null else ($s.delay // 0) end),
            probes: $all,
            failures: $fail,
            average_ms: (if $ok <= 0 then null else ns_to_ms($hp.average // 0) end),
            min_ms: (if $ok <= 0 then null else ns_to_ms($hp.min // 0) end),
            max_ms: (if $ok <= 0 then null else ns_to_ms($hp.max // 0) end),
            deviation_ms: (if $ok <= 0 then null else ns_to_ms($hp.deviation // 0) end),
            last_seen: null,
            last_try: null,
            last_error: null,
            source: "health_ping"
        }
      else
        {
            tag: $tag,
            # A node the observatory has never tried is not a dead node.
            # "alive" is absent for both, because omitempty drops false - so
            # absence alone proves nothing, and evidence of an attempt has to
            # be looked for: a try time, a delay, or a recorded error. Without
            # any of the three the honest answer is "not probed yet".
            state: (
                if $alive then "alive"
                elif (($s.last_try_time // 0) == 0)
                     and (($s.delay // 0) == 0)
                     and (($s.last_error_reason // "") == "") then "pending"
                else "dead"
                end
            ),
            delay_ms: (if $alive and (($s.delay // 0) != dead_delay) then ($s.delay // 0) else null end),
            probes: null,
            failures: null,
            average_ms: null,
            min_ms: null,
            max_ms: null,
            deviation_ms: null,
            last_seen: (($s.last_seen_time // 0) | if . == 0 then null else . end),
            last_try: (($s.last_try_time // 0) | if . == 0 then null else . end),
            last_error: (($s.last_error_reason // "") | if . == "" then null else . end),
            source: "probe"
        }
      end;

# A proxy outbound the engine reports traffic for, but the observatory says
# nothing about. Not the same as dead, and not the same as pending either - we
# simply have no observation, and the interface must say exactly that.
def node_unobserved($tag):
    {
        tag: $tag,
        state: "unobserved",
        delay_ms: null,
        probes: null,
        failures: null,
        average_ms: null,
        min_ms: null,
        max_ms: null,
        deviation_ms: null,
        last_seen: null,
        last_try: null,
        last_error: null,
        source: null
    };

def envelope($ok; $error; $detail):
    {
        ok: $ok,
        error: $error,
        detail: $detail,
        source: {address: $address, collected_at: $collected_at},
        traffic: null,
        distribution: null,
        observatory: null
    };

if (.stats | type) != "object" then
    # Valid JSON arrived, but not from an Xray metrics endpoint. Reporting this
    # apart from "unreachable" is the difference between "wrong port" and
    # "engine down", and the interface must not have to guess which.
    envelope(false; "metrics_no_stats"; {address: $address, http_code: 200, curl_exit: 0})
else
    (.stats.outbound | counters) as $outbound
    | (.stats.inbound | counters) as $inbound
    | (.observatory) as $obs
    | (if ($obs | type) == "object" then ($obs | keys) else [] end) as $observed_tags
    | (
        $outbound
        | keys
        | map(select(role(.) == "proxy"))
        | map(select(. as $t | $observed_tags | index($t) | not))
      ) as $unobserved_tags
    | envelope(true; null; null)
    + {
        traffic: {
            outbound: $outbound,
            inbound: $inbound,
            # Sum over outbounds - what actually left the router. Deliberately
            # not the inbound sum: the two differ, and a key called just
            # "total" would leave the interface guessing which one it got.
            outbound_total: ($outbound | sum_counters)
        },
        distribution: ($outbound | distribution),
        observatory: (
            if ($obs | type) != "object" then
                {state: "disabled", nodes: []}
            else
                {
                    state: "active",
                    nodes: (
                        ($obs | to_entries | map(node_from_status(.key; .value)))
                        + ($unobserved_tags | map(node_unobserved(.)))
                        | sort_by(.tag)
                    )
                }
            end
        )
    }
end
