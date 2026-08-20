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
