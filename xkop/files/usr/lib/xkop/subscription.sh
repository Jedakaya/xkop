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

# xkop asks under its own name. Measured on a live panel, and the result is
# worth stating precisely, because the obvious conclusion is the wrong one:
#
#   - the FORMAT is chosen by the path. "<url>/json" and "<url>/v2ray-json"
#     both return whole Xray configs; the bare url returns a link list. Our own
#     User-Agent gets the Xray format from those paths just as well as any
#     recognized client does.
#   - the CONTENT is unlocked by the device headers. Without X-HWID and the
#     rest the panel answers with a single stub server on port 1, whatever the
#     agent and whatever the path.
#
# So there is no reason to introduce ourselves as Happ or v2rayN. Passing for
# another client bought exactly nothing that the path suffix does not give.
XKOP_AGENT_DEFAULT="xkop/${XKOP_VERSION:-dev}"

# Tried in order; every one that answers contributes to the pool. A panel that
# does not know a suffix answers 404, which costs one request and is skipped.
XKOP_SOURCE_SUFFIXES='/json /v2ray-json ='

# uci list values may contain spaces, which the plain "uci get" spelling loses.
# On a router the OpenWrt helper does it properly; off a router it degrades to
# splitting, which is good enough for tests and never runs in production.
subscription_config_list() {
    local section="$1" option="$2"

    if [ -f /lib/functions.sh ]; then
        # Штатные функции OpenWrt не рассчитаны на строгий режим.
        #
        # При set -u они умирают на первой же необъявленной переменной:
        # "/lib/functions.sh: line 546: IPKG_INSTROOT: parameter not set".
        # Это выглядит безобидно — функция просто возвращает пустоту, — но
        # через неё читаются ВСЕ списки из uci: категории, свои домены,
        # свои подсети, ссылки, выученное Канарейкой. Пустота вместо них
        # означает конфигурацию без единого правила и весь трафик напрямую,
        # при внешне исправном роутере.
        #
        # Куплено ровно так: строгий режим добавлен в CLI по итогам аудита,
        # проверки прошли (в них эта функция подменена), на роутере правила
        # «были» — но пустые. Поэтому строгость здесь снимается и возвращается,
        # а не отменяется целиком.
        set +u
        # shellcheck source=/dev/null
        . /lib/functions.sh
        config_load "$XKOP_CONFIG" 2> /dev/null
        config_list_foreach "$section" "$option" _subscription_print_item
        set -u
        return 0
    fi

    uci -q get "$XKOP_CONFIG.$section.$option" 2> /dev/null | tr ' ' '\n' | grep -v '^$' || true
}

_subscription_print_item() {
    printf '%s\n' "$1"
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

# Panels put their own value in headers, base64 encoded when it is text.
subscription_header_value() {
    local headers="$1" name="$2" value

    value=$(grep -i "^$name:" "$headers" 2> /dev/null | head -n 1 | tr -d '\r')
    [ -n "$value" ] || return 0
    value="${value#*: }"

    case "$value" in
        base64:*) printf '%s' "${value#base64:}" | base64 -d 2> /dev/null ;;
        *) printf '%s' "$value" ;;
    esac
}

# What the panel says about itself and about us. This is the difference between
# "серверов нет" and "достигнут лимит устройств": the panel states the reason
# outright, and passing it through beats anything we could infer.
subscription_save_panel() {
    local headers="$1" id="$2" target

    [ -s "$headers" ] || return 0
    target="$(subscription_dir "$id")/panel.json"

    jq -nc \
        --arg title "$(subscription_header_value "$headers" 'profile-title')" \
        --arg announce "$(subscription_header_value "$headers" 'announce')" \
        --arg page "$(subscription_header_value "$headers" 'profile-web-page-url')" \
        --arg interval "$(subscription_header_value "$headers" 'profile-update-interval')" \
        --arg hwid_active "$(subscription_header_value "$headers" 'x-hwid-active')" \
        --arg hwid_limit "$(subscription_header_value "$headers" 'x-hwid-limit')" \
        --arg hwid_reached "$(subscription_header_value "$headers" 'x-hwid-max-devices-reached')" \
        '{
            title: (if $title == "" then null else $title end),
            announce: (if $announce == "" then null else $announce end),
            web_page: (if $page == "" then null else $page end),
            update_interval_days: (if $interval == "" then null else ($interval | tonumber? // null) end),
            hwid: {
                active: ($hwid_active == "true"),
                limited: ($hwid_limit == "true"),
                max_devices_reached: ($hwid_reached == "true")
            }
        }' > "$target.tmp" && mv "$target.tmp" "$target"
    chmod 600 "$target" 2> /dev/null || true
}

subscription_userinfo_of() {
    local file
    file="$(subscription_dir "$1")/userinfo.json"
    if [ -s "$file" ]; then
        cat "$file"
    else
        echo 'null'
    fi
}

subscription_panel() {
    local file
    file="$(subscription_dir "$1")/panel.json"
    if [ -s "$file" ]; then
        cat "$file"
    else
        echo 'null'
    fi
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

# The refresh itself. Every failure path here is written so that the router
# ends up no worse than it started: a bad answer never replaces a good cache,
# and a subscription that cannot be reached keeps serving what it already has.
subscription_update() {
    local id="$1"
    local url enabled include exclude dir work agents_file
    local agent n=0 ok=0 failed=0 fmt pool servers
    local merged count old_count fingerprint rejected now
    local agents_meta='[]'

    url=$(uci -q get "$XKOP_CONFIG.$id.url" 2> /dev/null)
    enabled=$(uci -q get "$XKOP_CONFIG.$id.enabled" 2> /dev/null)
    [ -n "$enabled" ] || enabled=1
    include=$(uci -q get "$XKOP_CONFIG.$id.include" 2> /dev/null)
    exclude=$(uci -q get "$XKOP_CONFIG.$id.exclude" 2> /dev/null)

    dir=$(subscription_dir "$id")
    now=$(date +%s)
    old_count=$(subscription_pool "$id" | jq 'length' 2> /dev/null)
    [ -n "$old_count" ] || old_count=0

    # An absent link is not a failure. In podkop it ended startup outright, and
    # before the scheduled jobs were installed - the router was then left
    # without a single way back.
    if [ -z "$url" ] || [ "$enabled" = "0" ]; then
        subscription_write_meta "$id" "absent" "no_url" "$now" 0 "$agents_meta"
        return 0
    fi

    mkdir -p "$dir" "$XKOP_RUN_DIR"
    chmod 700 "$dir" 2> /dev/null || true
    work="$XKOP_RUN_DIR/subscription-$id"
    rm -rf "$work"
    mkdir -p "$work"

    # One line per source: what to ask with, and what to ask for. By default
    # the agent is ours and the paths differ; a subscription may add agents of
    # its own for a panel that keys the format off the client instead.
    agents_file="$work/sources"
    : > "$agents_file"
    for suffix in $XKOP_SOURCE_SUFFIXES; do
        [ "$suffix" = "=" ] && suffix=""
        printf '%s\t%s\n' "$XKOP_AGENT_DEFAULT" "$url$suffix" >> "$agents_file"
    done
    subscription_config_list "$id" user_agent 2> /dev/null \
        | while IFS= read -r extra; do
            [ -n "$extra" ] && printf '%s\t%s\n' "$extra" "$url" >> "$agents_file"
        done

    while IFS="$(printf '\t')" read -r agent source_url; do
        [ -n "$agent" ] || continue
        [ -n "$source_url" ] || source_url="$url"
        n=$((n + 1))

        if ! subscription_fetch_one "$source_url" "$agent" "$work/ua-$n.payload" "$work/ua-$n.headers"; then
            failed=$((failed + 1))
            agents_meta=$(printf '%s' "$agents_meta" | jq -c \
                --arg a "$agent" --arg p "${source_url#"$url"}" \
                '. + [{agent: $a, path: $p, ok: false, format: null, servers: 0}]')
            continue
        fi

        subscription_decompress_gzip "$work/ua-$n.payload"
        fmt=$(subscription_detect_format "$work/ua-$n.payload")
        pool=$(subscription_pool_of "$work/ua-$n.payload" "$fmt" "$id")
        [ -n "$pool" ] || pool='[]'
        printf '%s' "$pool" > "$work/pool-$n.json"
        servers=$(printf '%s' "$pool" | jq 'length' 2> /dev/null)
        [ -n "$servers" ] || servers=0

        ok=$((ok + 1))
        agents_meta=$(printf '%s' "$agents_meta" | jq -c \
            --arg a "$agent" --arg p "${source_url#"$url"}" --arg f "$fmt" --argjson s "$servers" \
            '. + [{agent: $a, path: $p, ok: true, format: $f, servers: $s}]')

        if [ -s "$work/ua-$n.headers" ]; then
            subscription_save_userinfo "$work/ua-$n.headers" "$id"
            subscription_save_panel "$work/ua-$n.headers" "$id"
        fi
    done < "$agents_file"

    if [ "$ok" -eq 0 ]; then
        # Nothing arrived. The cache is left exactly as it was.
        if [ "$old_count" -gt 0 ]; then
            subscription_write_meta "$id" "stale" "download_failed" "$now" "$old_count" "$agents_meta"
        else
            subscription_write_meta "$id" "empty" "download_failed" "$now" 0 "$agents_meta"
        fi
        rm -rf "$work"
        return 0
    fi

    merged=$(cat "$work"/pool-*.json 2> /dev/null | jq -s -c \
        --arg mode merge --arg subscription "$id" --arg format "" \
        --arg include "$include" --arg exclude "$exclude" \
        -f "$XKOP_LIB_DIR/subscription.jq" 2> /dev/null)
    [ -n "$merged" ] || merged='[]'
    count=$(printf '%s' "$merged" | jq 'length' 2> /dev/null)
    [ -n "$count" ] || count=0

    fingerprint=$(cat "$work"/ua-*.payload 2> /dev/null | md5sum | cut -d' ' -f1)
    rejected=$(cat "$dir/rejected" 2> /dev/null)

    if [ "$count" -eq 0 ]; then
        # The panel refused, and said why. Passing its own words through beats
        # reporting "серверов нет" and letting the interface guess: a device
        # limit is not an empty subscription, and the fix is different.
        if [ "$(subscription_panel "$id" | jq -r '.hwid.max_devices_reached // false')" = "true" ]; then
            subscription_write_meta "$id" "blocked" "hwid_limit" "$now" "$old_count" "$agents_meta"
            rm -rf "$work"
            return 0
        fi

        # An answer with nothing usable in it. Remembering its fingerprint
        # keeps the next cycle from raising the same alarm over the same
        # rubbish, and the previous pool stays in place.
        if [ -n "$fingerprint" ] && [ "$fingerprint" = "$rejected" ]; then
            if [ "$old_count" -gt 0 ]; then
                subscription_write_meta "$id" "stale" "unchanged_rejected" "$now" "$old_count" "$agents_meta"
            else
                subscription_write_meta "$id" "rejected" "unchanged_rejected" "$now" 0 "$agents_meta"
            fi
        else
            printf '%s' "$fingerprint" > "$dir/rejected"
            if [ "$old_count" -gt 0 ]; then
                subscription_write_meta "$id" "stale" "empty_answer" "$now" "$old_count" "$agents_meta"
            else
                subscription_write_meta "$id" "empty" "empty_answer" "$now" 0 "$agents_meta"
            fi
        fi
        rm -rf "$work"
        return 0
    fi

    # Only here, with servers in hand, is the cache replaced - and by moving
    # files into place, never by writing over the ones in use.
    for f in "$work"/ua-*.payload; do
        [ -f "$f" ] || continue
        cp "$f" "$dir/$(basename "$f").tmp" && mv "$dir/$(basename "$f").tmp" "$dir/$(basename "$f")"
    done
    printf '%s' "$merged" > "$dir/pool.json.tmp" && mv "$dir/pool.json.tmp" "$dir/pool.json"
    printf '%s' "$url" > "$dir/url.tmp" && mv "$dir/url.tmp" "$dir/url"
    rm -f "$dir/rejected"
    chmod 600 "$dir"/* 2> /dev/null || true

    subscription_write_meta "$id" "ready" "" "$now" "$count" "$agents_meta"
    rm -rf "$work"
    return 0
}

subscription_write_meta() {
    local id="$1" state="$2" reason="$3" now="$4" servers="$5" agents="$6"
    local dir updated
    dir=$(subscription_dir "$id")
    mkdir -p "$dir"

    updated=$(subscription_meta "$id" | jq -r '.updated_at // empty' 2> /dev/null)
    [ "$state" = "ready" ] && updated="$now"

    jq -nc \
        --arg id "$id" --arg state "$state" --arg reason "$reason" \
        --argjson tried "$now" --argjson servers "$servers" --argjson agents "$agents" \
        --arg updated "$updated" \
        '{
            subscription: $id,
            state: $state,
            reason: (if $reason == "" then null else $reason end),
            tried_at: $tried,
            updated_at: (if $updated == "" then null else ($updated | tonumber) end),
            servers: $servers,
            agents: $agents
        }' > "$dir/meta.json.tmp" && mv "$dir/meta.json.tmp" "$dir/meta.json"
    chmod 600 "$dir/meta.json" 2> /dev/null || true
}

# Every subscription section of the configuration.
subscription_ids() {
    uci -q show "$XKOP_CONFIG" 2> /dev/null \
        | sed -n "s/^$XKOP_CONFIG\.\([^.=]*\)=subscription$/\1/p"
}

# Обновляет то, чему пора. Принудительно — когда просят руками: человек,
# нажавший «обновить», ждёт запроса к панели, а не рассказа про расписание.
subscription_update_all() {
    local id force="${1:-}"

    for id in $(subscription_ids); do
        if [ "$force" = "force" ] || subscription_due "$id"; then
            subscription_update "$id"
        fi
    done
}

# Неудачная загрузка при старте не должна висеть до следующего цикла.
#
# Подписки обновляются в prepare, то есть ДО того, как поднялся движок.
# На перезапуске это окно приходится ровно между «прежний движок убит»
# и «новый ответил», и скачивание в этот момент может не пройти. Дальше
# роутер до следующего срока живёт с красной строкой «подписки не готовы»
# при живом кэше, поднятом туннеле и пяти рабочих узлах — то есть
# сообщение говорит о беде, которой уже нет.
#
# Триггер на подъём интерфейса тут не спасает: WAN никуда не пропадал.
# Поэтому повтор привязан к тому единственному событию, которое означает
# «теперь точно можно»: движок ответил. Один раз и только тем, у кого
# причина в самой загрузке, — отказ панели или пустой ответ повторять
# незачем, ответ будет тот же.
subscription_retry_failed() {
    local id

    for id in $(subscription_ids); do
        case "$(subscription_meta "$id" | jq -r '.reason // ""')" in
            download_failed) subscription_update "$id" ;;
        esac
    done
}

# The merged pool of every subscription that has servers - what the
# configuration generator reads. A subscription in trouble contributes
# nothing and stops nothing.
subscription_pool_all() {
    local id work
    work="$XKOP_RUN_DIR/pool-all.$$"
    mkdir -p "$XKOP_RUN_DIR"
    : > "$work"

    for id in $(subscription_ids); do
        subscription_pool "$id" >> "$work"
        echo >> "$work"
    done

    jq -s -c --arg mode merge --arg subscription "" --arg format "" \
        -f "$XKOP_LIB_DIR/subscription.jq" < "$work" 2> /dev/null || echo '[]'
    rm -f "$work"
}

# "1h", "30m", "2d" -> seconds. An unparsable value falls back to an hour
# rather than to zero: zero would mean asking the panel on every cycle.
subscription_interval_seconds() {
    local raw="$1" number unit

    [ -n "$raw" ] || raw="1h"
    number=$(printf '%s' "$raw" | sed 's/[^0-9].*$//')
    unit=$(printf '%s' "$raw" | sed 's/^[0-9]*//' | cut -c1)
    [ -n "$number" ] || { printf '3600'; return 0; }

    case "$unit" in
        s) printf '%s' "$number" ;;
        m) printf '%s' "$((number * 60))" ;;
        d) printf '%s' "$((number * 86400))" ;;
        *) printf '%s' "$((number * 3600))" ;;
    esac
}

# Whether it is time to ask again. The schedule belongs to the subscription,
# and the cron job only wakes up often enough to notice.
subscription_due() {
    local id="$1" interval updated now

    interval=$(subscription_interval_seconds "$(uci -q get "$XKOP_CONFIG.$id.update_interval" 2> /dev/null)")
    updated=$(subscription_meta "$id" | jq -r '.updated_at // 0' 2> /dev/null)
    [ -n "$updated" ] || updated=0
    now=$(date +%s)

    # Never updated, or the cache holds nothing: ask now, whatever the
    # schedule says.
    [ "$updated" -eq 0 ] && return 0
    [ "$(subscription_pool "$id" | jq 'length' 2> /dev/null)" = "0" ] && return 0

    [ "$((now - updated))" -ge "$interval" ]
}
