#!/bin/sh
# shellcheck shell=ash
# Owner-defined network contract, never a script obtained from a job.
set -eu
config=${XKOP_FLEET_HEALTH_CONFIG:-/etc/xkop/fleet/health.json}
jq -e '
  (keys|sort)==["dns_name","dns_server","http_status","url"] and
  (.url|type=="string" and startswith("https://") and length<1024) and
  (.dns_name|type=="string" and length>0 and length<254 and
    ((explode-("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"|explode))|length==0)) and
  (.dns_server|type=="string" and length>0 and length<64 and
    ((explode-("0123456789abcdefABCDEF:."|explode))|length==0)) and
  (.http_status|type=="number" and floor==. and .>=200 and .<400)
' "$config" >/dev/null || exit 1
url=$(jq -r .url "$config")
expected=$(jq -r .http_status "$config")
name=$(jq -r .dns_name "$config")
server=$(jq -r .dns_server "$config")
case "$url" in *[!a-zA-Z0-9:/._?=%\&-]*) exit 1;; esac
[ "${1:-}" != validate ] || exit 0
case "${1:-}" in forward|rollback)
    /etc/init.d/dnsmasq restart
    /etc/init.d/xkop restart
    ;;
    baseline) ;;
    *) exit 1;;
esac
for attempt in 1 2 3 4 5 6; do
    : "$attempt"
    sleep 2
    [ -s /etc/xkop/config.json ] || continue
    jq -e '.inbounds|any(.tag=="tproxy-in")' /etc/xkop/config.json >/dev/null || continue
    port=$(jq -r '.inbounds[]|select(.tag=="probe-in" and .listen=="127.0.0.1")|.port' /etc/xkop/config.json)
    case "$port" in ''|*[!0-9]*) continue;; esac
    # Full engine config and transparent interception must both be present.
    xray run -test -config /etc/xkop/config.json >/dev/null 2>&1 || continue
    nft list table inet xkop >/dev/null 2>&1 || continue
    ip route list table 106 2>/dev/null | grep -q 'local default dev lo' || continue
    ip -4 rule list | grep -q 'fwmark 0x200000/0x200000 lookup 106' || continue
    tproxy_port=$(jq -r '.inbounds[]|select(.tag=="tproxy-in")|.port' /etc/xkop/config.json)
    tproxy_address=$(jq -r '.inbounds[]|select(.tag=="tproxy-in")|.listen' /etc/xkop/config.json)
    rules=$(nft list chain inet xkop proxy 2>/dev/null) || continue
    printf '%s' "$rules" | grep -F 'type filter hook prerouting' >/dev/null || continue
    printf '%s' "$rules" | grep -F "tproxy ip to $tproxy_address:$tproxy_port" >/dev/null || continue
    dig "@$server" "$name" A +short +time=2 +tries=1 | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' >/dev/null || continue
    log=/tmp/xkop/access.log
    [ -f "$log" ] || continue
    before=$(wc -l < "$log")
    random=$(hexdump -n 2 -e '1/2 "%u"' /dev/urandom)
    source_port=$((32768 + random % 27000))
    result=$(curl -q --noproxy '' --silent --proto '=https' --connect-timeout 3 --max-time 8 \
        --local-port "$source_port" --socks5-hostname "127.0.0.1:$port" "$url" -o /dev/null -w '%{http_code}') || continue
    [ "$result" = "$expected" ] || continue
    # HTTP alone could be routed direct; require a new actual tunnel log entry.
    tail -n +"$((before + 1))" "$log" | grep -F "127.0.0.1:$source_port " | grep -F '[probe-in -> ' | grep -v -E -- '-> (direct|block)\]' >/dev/null || continue
    exit 0
done
exit 1
