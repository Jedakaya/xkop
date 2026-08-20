# Subscription payload -> normalized server pool.
#
# Two of the three subscription formats are native to Xray, and for those the
# proxy outbound is copied as it came: that is the whole reason the project sits
# on this engine. Nothing is re-derived from fields we think we understand.
#
#   xray-config-list ("Happ format") - a JSON array where every element is a
#       complete Xray client config with its own outbounds and a "remarks"
#       display name. Shape confirmed by working podkop code, which detects it
#       exactly this way.
#   xray-json - a single Xray config object with an outbounds array.
#   link-list - a list of proxy URIs, which do have to be translated.
#
# Modes, all requiring $mode, $subscription and $format - jq resolves named
# arguments at compile time, so a missing one is an error rather than a null:
#
#   pool   input is one parsed payload, output is its servers
#   count  the same, output is how many
#   links  input is the raw text of a decoded link list (jq -R -s), output is
#          {servers, skipped}
#   merge  input is an array of pools, output is the deduplicated pool

def reserved_tags: ["direct", "block", "dns-out", "metrics-out", "api"];

# Outbound protocols that carry no traffic of ours. Names taken from the engine
# itself (infra/conf/xray.go outboundConfigLoader), including the aliases:
# "direct" is another name for freedom and "block" for blackhole.
def service_protocols: ["freedom", "direct", "blackhole", "block", "dns", "loopback"];

def format_rank($format):
    if $format == "xray-config-list" then 3
    elif $format == "xray-json" then 2
    elif $format == "link-list" then 1
    else 0
    end;

def is_proxy_outbound:
    . as $outbound
    | ($outbound.protocol | type) == "string"
    and ((service_protocols | index($outbound.protocol)) | not);

# Address, port and identity are pulled by walking the outbound rather than by
# a per-protocol table: vnext, servers and whatever a new protocol brings all
# carry the same field names, and an unknown protocol should end up deduplicated
# imprecisely rather than dropped.
def first_value($names):
    [ .. | objects | to_entries[] | select(.key as $k | $names | index($k)) | .value ]
    | map(select(. != null and . != ""))
    | first;

def endpoint_address: first_value(["address", "server"]) // null;
def endpoint_port: first_value(["port", "server_port"]) // null;
def endpoint_identity: first_value(["id", "password", "user", "auth"]) // null;

# Trimming by hand, without a regular expression: the jq package OpenWrt
# installs by default is built without oniguruma, and test/match/gsub simply do
# not exist there. Pulling in jq-full for a trim would cost flash on routers
# that have none to spare.
def trim:
    if . == null then null
    else
        (explode) as $c
        | ($c | length) as $n
        | [ range(0; $n)
            | select($c[.] != 32 and $c[.] != 9 and $c[.] != 10 and $c[.] != 13) ] as $keep
        | if ($keep | length) == 0 then ""
          else $c[($keep | first):(($keep | last) + 1)] | implode
          end
    end;

def sanitize_tag($raw):
    ($raw // "") | tostring | trim
    | if . == "" then "node" else . end;

def server($subscription; $format; $remarks; $outbound):
    ($outbound | endpoint_address) as $address
    | ($outbound | endpoint_port) as $port
    | ($outbound | endpoint_identity) as $identity
    | {
        tag: sanitize_tag($remarks // $outbound.tag),
        protocol: $outbound.protocol,
        address: $address,
        port: $port,
        identity: $identity,
        subscription: $subscription,
        format: $format,
        rank: format_rank($format),
        key: [$outbound.protocol, $address, $port, $identity],
        outbound: $outbound
    };

# A Happ element is one server delivered as a whole config: its proxy outbound
# is the payload, the direct and block outbounds around it are ours to generate.
def from_xray_config_list($subscription):
    [
        .[]
        | . as $config
        | ($config.outbounds // [])
        | map(select(is_proxy_outbound))
        | first
        | select(. != null)
        | server($subscription; "xray-config-list"; $config.remarks; .)
    ];

def from_xray_json($subscription):
    [
        (.outbounds // [])[]
        | select(is_proxy_outbound)
        | server($subscription; "xray-json"; .tag; .)
    ];

# --- proxy URI -> Xray outbound ------------------------------------------
#
# Everything here is measured against the engine's own JSON schema
# (infra/conf), because an outbound the engine refuses is not a missing server
# - it is a rejected configuration, which means no engine at all.
#
# Confirmed there, and easy to get wrong:
#   - Hysteria 2 is protocol "hysteria" with "version": 2, not "hysteria2".
#   - REALITY only works over RAW, XHTTP and gRPC; over websocket the engine
#     refuses to build the config.
#   - the h2, http and quic transports were removed and now raise an error.
#   - socks outbound speaks version 5 only, there is no version field.
# A link that would produce any of those is dropped with a reason instead.

def hexval($c):
    if $c >= 48 and $c <= 57 then $c - 48
    elif $c >= 97 and $c <= 102 then $c - 87
    elif $c >= 65 and $c <= 70 then $c - 55
    else null
    end;

# Percent encoding carries UTF-8 bytes, and a Cyrillic server name is three
# escapes per letter. Decoding byte by byte into codepoints keeps such names
# readable instead of turning them into mojibake in the interface.
def utf8_decode($bytes):
    reduce $bytes[] as $b (
        {cp: 0, need: 0, out: []};
        if .need > 0 then
            ((.cp * 64 + ($b - 128)) as $cp
             | if .need == 1 then {cp: 0, need: 0, out: (.out + [$cp])}
               else {cp: $cp, need: (.need - 1), out: .out}
               end)
        elif $b < 128 then {cp: 0, need: 0, out: (.out + [$b])}
        elif $b >= 240 then {cp: ($b - 240), need: 3, out: .out}
        elif $b >= 224 then {cp: ($b - 224), need: 2, out: .out}
        elif $b >= 192 then {cp: ($b - 192), need: 1, out: .out}
        else .
        end
    )
    | .out
    | implode;

def percent_decode:
    if . == null then null
    else
        (explode) as $c
        | ($c | length) as $n
        | reduce range(0; $n) as $i (
            {skip: 0, bytes: [], out: ""};
            if .skip > 0 then
                .skip -= 1
            elif $c[$i] == 37 and ($i + 2) < $n
                 and (hexval($c[$i + 1]) != null) and (hexval($c[$i + 2]) != null) then
                .bytes += [ hexval($c[$i + 1]) * 16 + hexval($c[$i + 2]) ]
                | .skip = 2
            else
                (if (.bytes | length) > 0 then
                    .out += utf8_decode(.bytes) | .bytes = []
                 else . end)
                | .out += ([$c[$i]] | implode)
            end
        )
        | (if (.bytes | length) > 0 then .out += utf8_decode(.bytes) else . end)
        | .out
    end;

def cut($sep):
    index($sep) as $i
    | if $i == null then [., null]
      else [.[0:$i], .[($i + ($sep | length)):]]
      end;

def rcut($sep):
    rindex($sep) as $i
    | if $i == null then [null, .]
      else [.[0:$i], .[($i + ($sep | length)):]]
      end;

def to_number: if . == null or . == "" then null else (tonumber? // null) end;

def parse_query:
    if . == null or . == "" then {}
    else
        split("&")
        | map(select(. != "") | cut("=")
              | {key: (.[0] | percent_decode), value: ((.[1] // "") | percent_decode)})
        | from_entries
    end;

def parse_hostport:
    . as $hostport
    | if $hostport == null or $hostport == "" then {address: null, port: null}
      elif startswith("[") then
        (index("]")) as $i
        | if $i == null then {address: $hostport, port: null}
          else {address: $hostport[1:$i],
                port: ($hostport[($i + 1):] | ltrimstr(":") | to_number)}
          end
      else
        (rcut(":")) as $parts
        | if $parts[0] == null then {address: $hostport, port: null}
          else {address: $parts[0], port: ($parts[1] | to_number)}
          end
      end;

def parse_link:
    (trim) as $line
    | ($line | cut("://")) as $head
    | if $head[1] == null then null
      else
        ($head[0] | ascii_downcase) as $scheme
        | ($head[1] | cut("#")) as $frag
        | ($frag[0] | cut("?")) as $query
        | (
            # Older shadowsocks links base64 the whole "method:password@host:port"
            # rather than the credentials alone. Unpacking it here keeps the rest
            # of the parser unaware that two spellings exist.
            if $scheme == "ss" and (($query[0] | index("@")) == null) then
                ((($query[0] | @base64d)? // $query[0]))
            else
                $query[0]
            end
          ) as $authority
        | ($authority | rcut("@")) as $auth
        | ($auth[1] | parse_hostport) as $hostport
        | {
            link: $line,
            scheme: $scheme,
            userinfo: $auth[0],
            address: $hostport.address,
            port: $hostport.port,
            params: ($query[1] | parse_query),
            remark: (($frag[1] // "") | percent_decode)
        }
      end;

def compact:
    with_entries(select(.value != null and .value != "" and .value != {} and .value != []));

def normalize_network($type):
    ($type // "" | ascii_downcase) as $t
    | if $t == "" or $t == "tcp" or $t == "raw" then "raw"
      elif $t == "ws" or $t == "websocket" then "ws"
      elif $t == "grpc" then "grpc"
      elif $t == "xhttp" or $t == "splithttp" then "xhttp"
      elif $t == "httpupgrade" then "httpupgrade"
      elif $t == "kcp" or $t == "mkcp" then "kcp"
      else null
      end;

def truthy($value):
    ($value // "" | tostring | ascii_downcase) as $v
    | $v == "1" or $v == "true" or $v == "yes";

def alpn_list($value):
    ($value // "")
    | if . == "" then null
      else split(",") | map(trim) | map(select(. != ""))
      end;

def transport_settings($network; $params; $address):
    ($params.path // "") as $path
    | ($params.host // "") as $host
    | if $network == "ws" then
        {wsSettings: ({
            path: (if ($params.ed // "") != "" and (($path | index("?")) == null)
                   then "\($path)?ed=\($params.ed)" else $path end),
            host: $host
        } | compact)}
      elif $network == "httpupgrade" then
        {httpupgradeSettings: ({path: $path, host: $host} | compact)}
      elif $network == "grpc" then
        {grpcSettings: ({
            serviceName: ($params.serviceName // ""),
            authority: ($params.authority // ""),
            multiMode: (($params.mode // "") == "multi")
        } | compact)}
      elif $network == "xhttp" then
        {xhttpSettings: ({
            path: $path,
            host: $host,
            mode: ($params.mode // ""),
            extra: (($params.extra // "") | if . == "" then null else (fromjson? // null) end)
        } | compact)}
      elif $network == "kcp" then
        {kcpSettings: ({
            seed: ($params.seed // ""),
            header: (($params.headerType // "") | if . == "" then null else {type: .} end)
        } | compact)}
      else
        {}
      end;

def security_settings($security; $params; $address; $allow_fingerprint):
    ($params.sni // "") as $sni
    | (if $allow_fingerprint then ($params.fp // "") else "" end) as $fingerprint
    | (truthy($params.allowInsecure // $params.insecure)) as $insecure
    | if $security == "reality" then
        {realitySettings: ({
            serverName: (if $sni == "" then null else $sni end),
            fingerprint: $fingerprint,
            publicKey: ($params.pbk // ""),
            shortId: ($params.sid // ""),
            spiderX: ($params.spx // "")
        } | compact)}
      elif $security == "tls" then
        {tlsSettings: (({
            serverName: (if $sni == "" then $address else $sni end),
            fingerprint: $fingerprint,
            alpn: alpn_list($params.alpn)
        } | compact) + (if $insecure then {allowInsecure: true} else {} end))}
      else
        {}
      end;

def normalize_security($params; $default):
    ($params.security // $default // "" | ascii_downcase) as $s
    | if $s == "" or $s == "none" then "none" else $s end;

def skipped($link; $reason): {link: $link, reason: $reason};

# Shadowsocks userinfo is either "method:password" or that same string in
# base64, and providers use both. Anything else is not a shadowsocks link.
def shadowsocks_userinfo($userinfo):
    ($userinfo // "") as $raw
    | if $raw == "" then null
      elif (($raw | index(":")) != null) then $raw
      else ((($raw | @base64d)? // null) as $decoded
            | if $decoded != null and (($decoded | index(":")) != null) then $decoded else null end)
      end;

def link_outbound($parsed):
    $parsed.scheme as $scheme
    | $parsed.params as $params
    | $parsed.address as $address
    | $parsed.port as $port
    | ($parsed.userinfo | percent_decode) as $userinfo
    # Scheme first, address second: a vmess link carries neither host nor port
    # outside its own base64 payload, and reporting that as "no port" would name
    # the wrong cause.
    | if (["vless", "trojan", "ss", "hysteria2", "hy2", "socks", "socks5"] | index($scheme) | not) then
        # socks4 and socks4a included: the engine's socks outbound speaks
        # version 5 only, and vmess links are not translated yet.
        skipped($parsed.link; "unsupported_scheme")
      elif $address == null or $address == "" then skipped($parsed.link; "no_address")
      elif $port == null then skipped($parsed.link; "no_port")

      elif $scheme == "vless" or $scheme == "trojan" then
        (normalize_network($params.type)) as $network
        | (normalize_security($params; "none")) as $security
        | if $network == null then skipped($parsed.link; "unsupported_transport")
          elif $security != "none" and $security != "tls" and $security != "reality" then
            skipped($parsed.link; "unsupported_security")
          elif $security == "reality"
               and ($network != "raw" and $network != "xhttp" and $network != "grpc") then
            # The engine refuses to build this combination outright.
            skipped($parsed.link; "reality_needs_raw_xhttp_or_grpc")
          else
            {
                protocol: (if $scheme == "vless" then "vless" else "trojan" end),
                settings: (
                    if $scheme == "vless" then
                        {vnext: [{
                            address: $address,
                            port: $port,
                            users: [ ({
                                id: $userinfo,
                                encryption: ($params.encryption // "none"),
                                flow: ($params.flow // "")
                            } | compact) ]
                        }]}
                    else
                        {servers: [ ({
                            address: $address,
                            port: $port,
                            password: $userinfo,
                            flow: ($params.flow // "")
                        } | compact) ]}
                    end
                ),
                streamSettings: (
                    {network: $network, security: $security}
                    + transport_settings($network; $params; $address)
                    + security_settings($security; $params; $address; true)
                )
            }
          end

      elif $scheme == "ss" then
        (shadowsocks_userinfo($userinfo)) as $credentials
        | if $credentials == null then skipped($parsed.link; "unreadable_credentials")
          else
            ($credentials | cut(":")) as $pair
            | {
                protocol: "shadowsocks",
                settings: {servers: [{
                    address: $address,
                    port: $port,
                    method: $pair[0],
                    password: ($pair[1] // "")
                }]}
            }
          end


      elif $scheme == "hysteria2" or $scheme == "hy2" then
        # Protocol name is "hysteria" with an explicit version, and the QUIC
        # transport carries the credentials a second time in hysteriaSettings.
        # A uTLS fingerprint is deliberately not passed on: providers copy fp=
        # onto hy2 links out of habit from vless, and over QUIC it is at best
        # ignored.
        (normalize_security($params; "tls")) as $security
        | {
            protocol: "hysteria",
            settings: {version: 2, address: $address, port: $port},
            streamSettings: (
                {network: "hysteria", security: $security}
                + security_settings($security; $params; $address; false)
                + {hysteriaSettings: {version: 2, auth: $userinfo}}
            )
        }

      elif $scheme == "socks5" or $scheme == "socks" then
        ($userinfo // "") as $credentials
        | ($credentials | cut(":")) as $pair
        | {
            protocol: "socks",
            settings: {servers: [ ({
                address: $address,
                port: $port,
                users: (if $credentials == "" then null
                        else [{user: ($pair[0] // ""), pass: ($pair[1] // "")}]
                        end)
            } | compact) ]}
        }

      else
        skipped($parsed.link; "unsupported_scheme")
      end;

def from_links($subscription):
    [ split("\n")[] | trim | select(. != "") ]
    | reduce .[] as $line (
        {servers: [], skipped: []};
        ($line | parse_link) as $parsed
        | if $parsed == null then
            # Not even a URI. Counted rather than dropped: a payload that turns
            # out to be a captive portal page must be visible as such.
            .skipped += [ skipped($line; "unreadable") ]
          else
            (link_outbound($parsed)) as $built
            | if $built.reason != null then
            .skipped += [$built]
          else
            .servers += [
                server($subscription; "link-list";
                       (if ($parsed.remark // "") == "" then $parsed.address else $parsed.remark end);
                       $built)
                | .notes = (
                    if ($parsed.params.obfs // "") != "" then ["obfs_ignored"] else [] end
                )
            ]
              end
          end
    );

def pool($subscription; $format):
    if $format == "xray-config-list" then from_xray_config_list($subscription)
    elif $format == "xray-json" then from_xray_json($subscription)
    else []
    end;

# Deduplication by protocol, address, port and identity. On a collision the
# richer format wins - the same server arrives from a Happ response with its
# transport intact and from a link list stripped down, and the stripped one
# must not overwrite it.
def dedupe:
    reduce .[] as $entry (
        {};
        ($entry.key | tojson) as $k
        | if (.[$k] == null) or (.[$k].rank < $entry.rank) then .[$k] = $entry else . end
    )
    | [ .[] ];

# Tags reach the engine, the balancer and the stats output, so they have to be
# unique and must never collide with the reserved outbound names - a node
# calling itself "direct" would be counted as direct traffic on the dashboard.
def assign_tags:
    reduce .[] as $entry (
        {used: {}, servers: []};
        (
            .used as $used
            | $entry.tag as $wanted
            | (
                if ($used[$wanted] == null) and ((reserved_tags | index($wanted)) | not) then
                    $wanted
                else
                    (
                        [ range(2; 100) | "\($wanted) #\(.)" ]
                        | map(select(. as $candidate | $used[$candidate] == null))
                        | first
                        // "\($wanted) #\($used | length + 100)"
                    )
                end
            )
        ) as $tag
        | .used[$tag] = true
        | .servers += [ $entry | .tag = $tag | .outbound.tag = $tag ]
    )
    | .servers;

# Keyword filters from the subscription section. Case is ignored: a provider
# writes "Info" today and "INFO" tomorrow, and a filter that notices the
# difference silently stops filtering.
#
# Passed through $ARGS.named rather than as declared arguments, so callers that
# do not filter need not know these exist.
def keywords($raw):
    ($raw // "") | ascii_downcase | split(" ") | map(select(. != ""));

def apply_filters:
    keywords($ARGS.named.include) as $include
    | keywords($ARGS.named.exclude) as $exclude
    | map(
        (.tag // "" | ascii_downcase) as $tag
        | select(
            (($include | length) == 0 or any($include[]; . as $k | $tag | contains($k)))
            and (($exclude | length) == 0 or all($exclude[]; . as $k | ($tag | contains($k)) | not))
        )
      );

def merge:
    add
    | apply_filters
    | dedupe
    | sort_by(.subscription, .tag, (.key | tojson))
    | assign_tags;

if $mode == "pool" then
    pool($subscription; $format)
elif $mode == "count" then
    (if $format == "link-list" then
        from_links($subscription) | .servers | length
     else
        pool($subscription; $format) | length
     end)
elif $mode == "links" then
    from_links($subscription)
elif $mode == "merge" then
    merge
else
    error("unknown mode: \($mode)")
end
