#!/bin/sh
# shellcheck shell=ash
# Subscription payload: what arrived and whether anything usable is in it.
#
# Format knowledge is taken from working podkop code, where it was proven
# against live panels:
#
#   xray-config-list  JSON array, each element a complete Xray client config
#                     ("Happ format"). Panels hand it to Happ-style User-Agents
#                     and only there do Hysteria2 servers show up.
#   xray-json         a single Xray config object with an outbounds array.
#   link-list         base64 blob decoding to one proxy URI per line, what a
#                     v2rayN-style User-Agent gets instead.
#
# Extraction of servers lives in subscription.jq. This file only answers what
# the payload is and how much of it is usable, because the subscription state
# machine needs that answer before it may replace a working cache.

XKOP_LINK_SCHEME_REGEX='^(socks4a?|socks5?|vless|vmess|ss|trojan|hysteria2|hy2)://'

# Some providers gzip the body no matter what Accept-Encoding said, and curl
# neither asks for it nor unpacks it. Without this the payload reaches format
# detection as opaque binary and the reported reason names the wrong problem.
subscription_decompress_gzip() {
    local file="$1" tmpfile

    [ -s "$file" ] || return 0
    gzip -t "$file" 2> /dev/null || return 0

    tmpfile="$file.gunzip.$$"
    if gzip -dc "$file" > "$tmpfile" 2> /dev/null && [ -s "$tmpfile" ]; then
        mv "$tmpfile" "$file"
    else
        rm -f "$tmpfile"
    fi
}

# Decodes the link list to one trimmed URI per line. Panels differ in the
# alphabet and in whether they pad, so a strict decoder alone loses whole
# subscriptions: the url-safe alphabet is retried with padding restored.
subscription_looks_binary() {
    [ "$(LC_ALL=C tr -d '[:print:][:space:]' < "$1" | wc -c | tr -d ' ')" -gt 0 ]
}

subscription_decode_link_list() {
    local file="$1" blob decoded padding

    # A base64 blob is text by definition. Bailing out early keeps a binary
    # payload - a still compressed body, an image, an error page from a captive
    # portal - out of command substitution, which would otherwise choke on null
    # bytes and say so on stderr.
    subscription_looks_binary "$file" && return 0

    blob=$(tr -d '[:space:]' < "$file")
    [ -n "$blob" ] || return 0

    # The alphabet is normalized BEFORE decoding, always - never as a retry
    # after a failed attempt. GNU base64 stops at the first character outside
    # its alphabet and prints what it managed to decode, exit code and all: a
    # url-safe payload then yields a silently truncated list instead of an
    # error, and the servers past the first "-" or "_" simply disappear.
    # Neither "+" nor "/" can occur in a url-safe payload, so translating is
    # safe for both alphabets.
    blob=$(printf '%s' "$blob" | tr '_-' '/+')

    padding=$((${#blob} % 4))
    case "$padding" in
        2) blob="$blob==" ;;
        3) blob="$blob=" ;;
        1) return 0 ;;
    esac

    decoded=$(printf '%s' "$blob" | base64 -d 2> /dev/null)
    [ -n "$decoded" ] || return 0

    printf '%s\n' "$decoded" | tr -d '\r' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | grep -v '^$'
}

# One of: xray-config-list, xray-json, link-list, unknown.
subscription_detect_format() {
    local file="$1"

    if [ ! -s "$file" ]; then
        echo "unknown"
        return 0
    fi

    if jq -e 'type == "array" and length > 0
              and all(.[]; type == "object" and (.outbounds | type == "array"))' \
        "$file" > /dev/null 2>&1; then
        echo "xray-config-list"
        return 0
    fi

    # sing-box config first, because it is also an object with an outbounds
    # array and would otherwise pass for an Xray one. Checked on a live panel:
    # a sing-box User-Agent gets exactly this, and calling it xray-json makes
    # the subscription look empty instead of saying the format is wrong.
    if jq -e 'type == "object" and (.outbounds | type == "array")
              and (any(.outbounds[]?; has("type")) and all(.outbounds[]?; has("protocol") | not))' \
        "$file" > /dev/null 2>&1; then
        echo "sing-box-json"
        return 0
    fi

    if jq -e 'type == "object" and (.outbounds | type == "array")' \
        "$file" > /dev/null 2>&1; then
        echo "xray-json"
        return 0
    fi

    if subscription_decode_link_list "$file" | grep -qE "$XKOP_LINK_SCHEME_REGEX"; then
        echo "link-list"
        return 0
    fi

    echo "unknown"
}

# Servers of one payload, as a JSON array. The link list needs its own input
# mode: it is raw text by the time it gets here, not JSON.
subscription_pool_of() {
    local file="$1" format="$2" id="$3"

    case "$format" in
        xray-config-list | xray-json)
            jq -c --arg mode pool --arg subscription "$id" --arg format "$format" \
                -f "$XKOP_LIB_DIR/subscription.jq" "$file" 2> /dev/null
            ;;
        link-list)
            subscription_decode_link_list "$file" \
                | jq -c --arg mode links --arg subscription "$id" --arg format "$format" \
                    -f "$XKOP_LIB_DIR/subscription.jq" 2> /dev/null \
                | jq -c '.servers' 2> /dev/null
            ;;
        *)
            echo '[]'
            ;;
    esac
}

# How many servers the payload actually yields. Zero is the ПУСТАЯ state of
# docs/subscription.md: the answer arrived and parsed, there is just nothing
# in it - which is not the same failure as a payload we could not read.
subscription_count_servers() {
    local file="$1" format="$2" count

    case "$format" in
        xray-config-list | xray-json)
            count=$(jq -r --arg mode count --arg subscription '' --arg format "$format" \
                -f "$XKOP_LIB_DIR/subscription.jq" "$file" 2> /dev/null)
            ;;
        link-list)
            # Usable ones, not all of them: a link the engine cannot build an
            # outbound from never becomes a server, and promising it would make
            # an empty subscription look populated.
            count=$(subscription_decode_link_list "$file" \
                | jq -R -s -r --arg mode count --arg subscription '' --arg format link-list \
                    -f "$XKOP_LIB_DIR/subscription.jq" 2> /dev/null)
            ;;
        *)
            count=0
            ;;
    esac

    [ -n "$count" ] || count=0
    printf '%s' "$count"
}

# --- cache and state ------------------------------------------------------
#
# One directory per subscription. The cache lives on the persistent partition
# because a router that lost power and has no internet must still come up
# routing: the last usable payload is the source of truth at start, and the
# network is needed to refresh it, not to boot.
#
#   ua-<n>.payload   raw answer per User-Agent
#   pool.json        merged servers, what the configuration generator reads
#   meta.json        state, when, from what, how many, why not
#   rejected         fingerprint of an answer already found unusable
#   userinfo.json    traffic and expiry, if the provider sends them
#
# States describe what we HAVE, and the reason describes the last attempt:
#
#   ready     серверы есть, последнее обновление удалось
#   stale     серверы есть, последнее обновление не удалось - работаем на кэше
#   empty     серверов нет: ответ разобрался, но в нём ничего нет
#   rejected  ответ совпал с отпечатком уже отвергнутого
#   absent    ссылки нет или подписка выключена
#
# The one transition that must never happen is ready -> absent: a failed
# refresh may not take away a working cache.

subscription_dir() {
    printf '%s/%s' "$XKOP_CACHE_DIR" "$1"
}

subscription_meta() {
    local file
    file="$(subscription_dir "$1")/meta.json"
    if [ -s "$file" ]; then
        cat "$file"
    else
        jq -nc --arg id "$1" '{subscription: $id, state: "absent", reason: "no_cache",
                               updated_at: null, tried_at: null, servers: 0}'
    fi
}

subscription_pool() {
    local file
    file="$(subscription_dir "$1")/pool.json"
    if [ -s "$file" ]; then
        cat "$file"
    else
        echo '[]'
    fi
}

# Traffic and expiry come in a header, not in the body. Saved only when the
# provider actually sent numbers - an empty block on the dashboard is better
# than four zeroes that look like an exhausted subscription.
subscription_save_userinfo() {
    local headers="$1" id="$2" line value upload download total expire target

    [ -s "$headers" ] || return 0
    line=$(grep -i '^subscription-userinfo:' "$headers" | head -n 1 | tr -d '\r')
    [ -n "$line" ] || return 0

    value="${line#*: }"
    upload=$(printf '%s' "$value" | grep -oE 'upload=[0-9]+' | cut -d= -f2)
    download=$(printf '%s' "$value" | grep -oE 'download=[0-9]+' | cut -d= -f2)
    total=$(printf '%s' "$value" | grep -oE 'total=[0-9]+' | cut -d= -f2)
    expire=$(printf '%s' "$value" | grep -oE 'expire=[0-9]+' | cut -d= -f2)

    upload=${upload:-0}; download=${download:-0}; total=${total:-0}; expire=${expire:-0}
    [ "$upload" = "0" ] && [ "$download" = "0" ] && [ "$total" = "0" ] && [ "$expire" = "0" ] && return 0

    target="$(subscription_dir "$id")/userinfo.json"
    jq -nc --argjson upload "$upload" --argjson download "$download" \
        --argjson total "$total" --argjson expire "$expire" \
        '{upload: $upload, download: $download, total: $total, expire: $expire}' \
        > "$target.tmp" && mv "$target.tmp" "$target"
    chmod 600 "$target" 2> /dev/null || true
}

subscription_device_model() {
    if [ -f /tmp/sysinfo/model ]; then
        cat /tmp/sysinfo/model 2> /dev/null
    else
        echo "OpenWrt Router"
    fi
}

# Deterministic per router: the same device always presents the same id, so a
# panel counting devices does not see a new one after every reboot. The recipe
# is deliberately identical to podkop's, down to the interface order - a router
# migrating from it keeps the id it was already known by.
subscription_hwid() {
    local mac="" model raw

    if [ -f /sys/class/net/eth0/address ]; then
        mac=$(cat /sys/class/net/eth0/address 2> /dev/null)
    elif [ -f /sys/class/net/br-lan/address ]; then
        mac=$(cat /sys/class/net/br-lan/address 2> /dev/null)
    fi

    model=$(subscription_device_model)
    raw=$(printf '%s-%s' "$mac" "$model" | md5sum | cut -c1-16)

    printf '%s-%s-%s-%s' \
        "$(echo "$raw" | cut -c1-4)" "$(echo "$raw" | cut -c5-8)" \
        "$(echo "$raw" | cut -c9-12)" "$(echo "$raw" | cut -c13-16)"
}

# One request with one User-Agent. Different agents get different formats and
# different sets of servers from the same panel, which is why they are asked
# separately rather than one being chosen - see docs/subscription.md.
#
# The client headers are not decoration. Checked against a live panel: without
# them the answer is a single stub server on port 1 named "Приложение не
# поддерживается или выключена отправка HWID". With them the same URL and the
# same User-Agent return the real list. A subscription that looks empty is
# almost always this.
subscription_fetch_one() {
    local url="$1" agent="$2" outfile="$3" headers="$4"

    curl -fsSL --compressed --max-time 60 --retry 2 --retry-delay 2 \
        -A "$agent" \
        -H "X-HWID: $(subscription_hwid)" \
        -H "X-Device-OS: OpenWrt Linux" \
        -H "X-Device-Model: $(subscription_device_model)" \
        -H "X-Ver-OS: $(uname -r)" \
        -H "Accept-Language: ru-RU,en,*" \
        -H "X-Device-Locale: EN" \
        -D "$headers" -o "$outfile" "$url" 2> /dev/null
}
