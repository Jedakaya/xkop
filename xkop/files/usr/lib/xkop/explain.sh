#!/bin/sh
# shellcheck shell=ash
# Разбор маршрута: почему этот сайт ведёт себя так, а не иначе.
#
# The answer is an observation, not a reading of our own rules. The engine
# writes one line per connection into the access log, and in that line is the
# outbound it chose:
#
#   2026/08/20 18:07:11 from tcp:192.168.1.50:41234 accepted tcp:openwrt.org:443 [tproxy-in -> direct]
#
# So the question "where does this name go" is answered by making the engine
# answer it - a probe through the loopback inbound - and then reading what it
# did. Anything else would be our interpretation of our own configuration,
# which is exactly the kind of confident wrong answer this project is written
# against.

access_log_path() {
    printf '%s' "${XKOP_ACCESS_LOG:-/tmp/xkop/access.log}"
}

access_log_enabled() {
    local setting
    setting=$(config_uci_get settings access_log)
    [ -z "$setting" ] || [ "$setting" = "1" ]
}

# The log lives in RAM and grows with every connection. Trimmed to the tail,
# because the recent past is what any of this is for.
access_trim() {
    local file size_kb keep
    file=$(access_log_path)
    [ -f "$file" ] || return 0

    size_kb=$(( ($(wc -c < "$file") + 1023) / 1024 ))
    [ "$size_kb" -le "${XKOP_ACCESS_LOG_MAX_KB:-2048}" ] && return 0

    # Половина от порога, но не ноль: при маленьком пороге целочисленное
    # деление даёт ноль, и "подрезка" вычищала журнал целиком.
    keep=$(( ${XKOP_ACCESS_LOG_MAX_KB:-2048} / 2 ))
    [ "$keep" -lt 1 ] && keep=1
    tail -c "$((keep * 1024))" "$file" > "$file.tmp" 2> /dev/null \
        && cat "$file.tmp" > "$file" \
        && rm -f "$file.tmp"

    # The file is truncated in place rather than replaced: the engine holds it
    # open, and a new inode would leave it writing into something nobody can
    # read any more.
    log_info "журнал доступа подрезан до ${keep} КБ"
}

# Lines about one name, newest last. Matching on ":<name>:" keeps
# "notexample.com" out of the answer for "example.com".
access_lines_for() {
    local domain="$1" file
    file=$(access_log_path)
    [ -f "$file" ] || return 0
    grep -F ":$domain:" "$file" 2> /dev/null
}

# The separator in the log is not decoration. Read from the engine's own
# dispatcher, it says HOW the outbound was chosen:
#
#   inbound ->  outbound   a routing rule matched
#   inbound >>  outbound   nothing matched, the default outbound was used
#   inbound ==> outbound   the outbound was forced from outside the rules
#
# That distinction is the whole answer to "почему этот сайт ведёт себя так":
# a name that fell through to the default is a name that is in no list.
access_line_outbound() {
    printf '%s' "$1" | sed -n 's/.*\[[^]]*[-=>][=>] \([^]]*\)\].*/\1/p' | tail -n 1
}

access_line_reason() {
    case "$1" in
        *'==> '*) echo "forced" ;;
        *' -> '*) echo "rule" ;;
        *' >> '*) echo "default" ;;
        *) echo "" ;;
    esac
}

# Asks the engine by making it do the thing. The probe goes through the
# loopback socks inbound, so it travels the same rules as a client would.
explain_probe() {
    local domain="$1" port

    port="${XKOP_PROBE_PORT:-10809}"
    command -v curl > /dev/null 2>&1 || return 1

    curl -s --max-time 6 -o /dev/null \
        --socks5-hostname "127.0.0.1:$port" "https://$domain/" 2> /dev/null
    return 0
}

# What our own configuration says about the name. Reported beside the
# observation, never instead of it: community lists are resolved inside the
# engine, and from here their contents are unknown.
explain_rules() {
    local domain="$1"

    if [ ! -s "$XKOP_CONFIG_PATH" ]; then
        echo 'null'
        return 0
    fi

    jq -c --arg domain "$domain" '
        [ .routing.rules[]
          | select(.domain != null)
          | . as $rule
          | ($rule.domain | map(select(
                . == $domain
                or ($domain | endswith("." + .))
                or (startswith("geosite:"))
            ))) as $matched
          | select(($matched | length) > 0)
          | {
                target: (.balancerTag // .outboundTag),
                matched: $matched,
                # A geosite reference is not resolved here on purpose: only the
                # engine knows what is inside the list, and pretending
                # otherwise would be a guess wearing the clothes of a fact.
                certain: ($matched | all(startswith("geosite:") | not))
            }
        ] | first // null
    ' "$XKOP_CONFIG_PATH"
}

# Поддельный ли адрес.
#
# Диапазон FakeIP наш собственный и неизменный, поэтому сверяются два первых
# октета, а не разбирается маска. Что он именно такой, стережёт проверка
# в tests/explain.test.sh: сменится константа - упадёт она, а не роутер.
explain_is_fake() {
    case "$1" in
        198.18.*.* | 198.19.*.*) return 0 ;;
    esac
    return 1
}

# Во что имя разрешается и попадает ли этот адрес в перехват.
#
# «Ни одно правило не совпало» само по себе не отвечает на вопрос, почему сайт
# не открывается: правило может не совпасть, а сайт при этом жить на адресе,
# который режет провайдер. Чтобы это увидеть, нужны две вещи — адрес и ответ,
# есть ли он в наборе. На живом роутере выяснение ровно этого заняло три часа
# и дамп трафика: App Store уходил напрямую на Fastly, а Fastly у провайдера
# рвут.
#
# Поддельный адрес — не «мимо перехвата», а наоборот: имя ведёт в движок,
# и решение принимается там, по имени.
explain_addresses() {
    local domain="$1" address result='[]' fake inside

    command -v nslookup > /dev/null 2>&1 || { echo 'null'; return 0; }

    for address in $(nslookup "$domain" 127.0.0.1 2> /dev/null \
        | sed -n 's/^Address[^:]*:[[:space:]]*//p' | grep -v ':'); do

        if explain_is_fake "$address"; then fake=true; else fake=false; fi
        if nft_routed_contains "$address"; then inside=true; else inside=false; fi

        result=$(printf '%s' "$result" | jq -c \
            --arg address "$address" --argjson fake "$fake" --argjson inside "$inside" \
            '. + [{address: $address, fake: $fake, intercepted: $inside}]')
    done

    printf '%s' "$result"
}

explain_domain() {
    local domain="$1" observed line outbound reason rules requests probed=0

    if [ -z "$domain" ]; then
        jq -nc '{ok: false, error: "no_domain"}'
        return 0
    fi

    if ! access_log_enabled; then
        jq -nc --arg domain "$domain" \
            '{ok: false, error: "access_log_off", detail: {domain: $domain},
              hint: "uci set xkop.settings.access_log=1 и перезапуск"}'
        return 0
    fi

    if engine_answers; then
        explain_probe "$domain"
        probed=1
        # The engine writes the line as the connection is accepted; a moment is
        # needed before it can be read back.
        sleep 1
    fi

    observed=$(access_lines_for "$domain")
    line=$(printf '%s' "$observed" | tail -n 1)
    outbound=$(access_line_outbound "$line")
    reason=$(access_line_reason "$line")
    rules=$(explain_rules "$domain")

    # grep -c печатает ноль и завершается единицей, когда совпадений нет.
    # Подстраховка через "|| echo 0" дописывала второй ноль, и получался
    # не JSON, а два числа.
    requests=$(printf '%s' "$observed" | grep -c . 2> /dev/null)
    [ -n "$requests" ] || requests=0

    jq -nc \
        --arg domain "$domain" \
        --arg outbound "$outbound" \
        --arg reason "$reason" \
        --arg line "$line" \
        --argjson probed "$probed" \
        --argjson rules "${rules:-null}" \
        --argjson pool "$(subscription_pool_all)" \
        --argjson addresses "$(explain_addresses "$domain")" \
        --argjson requests "$requests" \
        '
        ($pool | map(select(.tag == $outbound)) | first) as $node
        | {
            ok: true,
            domain: $domain,
            probed: ($probed == 1),
            observed: ($outbound != ""),
            outbound: (if $outbound == "" then null else $outbound end),
            role: (
                if $outbound == "" then null
                elif $outbound == "direct" then "напрямую"
                elif $outbound == "block" then "заблокировано"
                elif $node != null then "через туннель"
                else "служебное"
                end
            ),
            node: (if $node == null then null else {
                tag: $node.tag, protocol: $node.protocol, subscription: $node.subscription
            } end),
            matched_rule: (if $reason == "" then null else ($reason == "rule") end),
            why: (
                if $reason == "rule" then "совпало правило маршрутизации"
                elif $reason == "default" then "ни одно правило не совпало, ушёл по умолчанию"
                elif $reason == "forced" then "исходящий назначен принудительно"
                else null
                end
            ),
            rule: $rules,
            addresses: $addresses,
            hint: (
                # Один случай стоит отдельной строки, потому что снаружи
                # выглядит как что угодно, только не как своя причина: имя
                # ушло напрямую, адрес настоящий, и в перехват он не попадает.
                # Если сайт при этом не открывается, дело не в маршрутизации,
                # а в том, что до этого адреса не дают дойти.
                if $outbound == "direct" and $addresses != null
                   and (($addresses
                         | map(select(.fake == false and .intercepted == false))
                         | length) > 0)
                then "идёт напрямую, и адрес в перехват не попадает: если сайт не открывается, добавьте его подсеть в профиль"
                else null
                end
            ),
            requests_seen: $requests,
            last_line: (if $line == "" then null else $line end),
            state: (
                if $outbound != "" then "наблюдение: соединение ушло в \($outbound)"
                elif ($probed == 1) then "проба сделана, но записи о ней нет — движок мог её не принять"
                else "движок не отвечает, наблюдать нечем"
                end
            )
        }'
}

# Names that went somewhere other than expected, straight from the log: what
# actually happened, grouped. The reverse question of the one above, and the
# one that finds mistakes nobody thought to look for.
explain_recent() {
    local limit="${1:-20}" file tab
    file=$(access_log_path)

    if [ ! -s "$file" ]; then
        jq -nc '{ok: false, error: "no_access_log"}'
        return 0
    fi

    # Разделитель — табуляция, а не пробел: имя узла приходит из подписки
    # и запросто содержит пробелы, флаги и скобки. По пробелу «🇩🇪 Германия
    # (если нет ограничений)» превращается в «🇩🇪», и в отчёте оказывается
    # узел, которого нет.
    tab=$(printf '\t')

    tail -n 2000 "$file" \
        | sed -n "s/.*accepted [a-z]*:\([^ ]*\):[0-9]* \[[^]]*[-=>][=>] \([^]]*\)\].*/\1$tab\2/p" \
        | sort | uniq -c | sort -rn | head -n "$limit" \
        | sed -n "s/^ *\([0-9][0-9]*\) \(.*\)$/\1$tab\2/p" \
        | jq -R -s -c --argjson limit "$limit" '
            {
                ok: true,
                limit: $limit,
                domains: [
                    split("\n")[] | select(. != "") | split("\t")
                    | {domain: .[1], outbound: .[2], requests: (.[0] | tonumber)}
                ]
            }'
}
