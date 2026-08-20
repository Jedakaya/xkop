#!/bin/sh
# shellcheck shell=ash
# Configuration: uci and the subscription pool -> a validated Xray config.
#
# The shape of the work is deliberate. Everything uncertain is collected here,
# in shell, into one JSON object; the generation itself is a pure function in
# config.jq. That way the generator can be run against a recorded input and the
# result checked by the engine itself, without a router in the loop.
#
# The invariant that governs installation is not negotiable: an invalid
# configuration is never installed, and a failed generation never cancels a
# start. The engine keeps running on the last configuration known to work,
# because a rejected configuration means no engine, and no engine on a router
# whose traffic goes through it means no network at all.

config_uci_get() {
    uci -q get "$XKOP_CONFIG.$1.$2" 2> /dev/null
}

config_uci_list_json() {
    subscription_config_list "$1" "$2" 2> /dev/null | jq -R -s -c 'split("\n") | map(select(. != ""))'
}

config_section_ids() {
    uci -q show "$XKOP_CONFIG" 2> /dev/null \
        | sed -n "s/^$XKOP_CONFIG\.\([^.=]*\)=$1$/\1/p"
}

config_settings_json() {
    jq -nc \
        --arg log_level "$(config_uci_get settings log_level)" \
        --arg metrics_port "$(config_uci_get settings metrics_port)" \
        --arg api_port "$XKOP_API_PORT_DEFAULT" \
        --arg probe_port "$XKOP_PROBE_PORT" \
        --arg access_log "$(config_uci_get settings access_log)" \
        --arg access_log_path "$XKOP_ACCESS_LOG" \
        --arg tproxy_address "$XKOP_TPROXY_ADDRESS" \
        --arg tproxy_port "$XKOP_TPROXY_PORT" \
        --arg strategy "$(config_uci_get settings strategy)" \
        --arg probe_url "$(config_uci_get settings probe_url)" \
        --arg probe_interval "$(config_uci_get settings probe_interval)" \
        --arg block_client_doh "$(config_uci_get settings block_client_doh)" \
        --arg disable_quic "$(config_uci_get settings disable_quic)" \
        --arg dns_mode "$(config_uci_get settings dns_mode)" \
        --arg dns_server "$(config_uci_get settings dns_server)" \
        --arg dns_type "$(config_uci_get settings dns_type)" \
        --arg dns_bootstrap "$(config_uci_get settings dns_bootstrap)" \
        --arg dns_parallel "$(config_uci_get settings dns_parallel)" \
        --arg output_interface "$(config_uci_get settings output_interface)" \
        --arg dns_address "$XKOP_DNS_INBOUND_ADDRESS" \
        --arg dns_port "$XKOP_DNS_INBOUND_PORT" \
        --arg fakeip_range "$XKOP_FAKEIP_RANGE" \
        --argjson dns_extra "$(config_uci_list_json settings dns_extra_server)" \
        --argjson canary_learned "$(config_uci_list_json settings canary_learned_ip)" \
        --argjson fully_routed "$(config_uci_list_json settings fully_routed_ip)" \
        '{
            dns_mode: (if $dns_mode == "" then "off" else $dns_mode end),
            block_client_doh: (if $block_client_doh == "" then "0" else $block_client_doh end),
            disable_quic: (if $disable_quic == "" then "0" else $disable_quic end),
            dns_server: (if $dns_server == "" then "8.8.8.8" else $dns_server end),
            dns_type: (if $dns_type == "" then "doh" else $dns_type end),
            dns_bootstrap: $dns_bootstrap,
            dns_parallel: (if $dns_parallel == "" then "0" else $dns_parallel end),
            output_interface: $output_interface,
            dns_address: $dns_address,
            dns_port: (($dns_port | tonumber?) // 53),
            fakeip_range: $fakeip_range,
            dns_extra: $dns_extra,
            canary_learned: $canary_learned,
            fully_routed_ip: $fully_routed
        } + {
            log_level: (if $log_level == "" then "warning" else $log_level end),
            metrics_port: (($metrics_port | tonumber?) // 11111),
            api_port: (($api_port | tonumber?) // 11112),
            probe_port: (($probe_port | tonumber?) // 10809),
            access_log: (if $access_log == "" then "1" else $access_log end),
            access_log_path: $access_log_path,
            tproxy_address: $tproxy_address,
            tproxy_port: (($tproxy_port | tonumber?) // 1608),
            strategy: (if $strategy == "" then "leastLoad" else $strategy end),
            probe_url: (if $probe_url == "" then null else $probe_url end),
            probe_interval: (if $probe_interval == "" then null else $probe_interval end)
        }'
}

# Подсети категорий, выбранных в профиле. Домены категории движок берёт сам
# из geosite, а адреса лежат отдельным файлом и попадают в то же правило —
# см. lists.sh, там же сказано, почему без этого Telegram не маршрутизируется.
config_community_subnets_json() {
    local id="$1" category

    {
        for category in $(subscription_config_list "$id" community_list 2> /dev/null); do
            lists_subnet_entries "$category"
        done
    } | jq -R -s -c 'split("\n") | map(select(. != "")) | unique'
}

config_profile_json() {
    local id="$1"

    jq -nc \
        --arg id "$id" \
        --arg title "$(config_uci_get "$id" title)" \
        --argjson community "$(config_uci_list_json "$id" community_list)" \
        --argjson community_subnet "$(config_community_subnets_json "$id")" \
        --argjson domain "$(config_uci_list_json "$id" domain)" \
        --argjson subnet "$(config_uci_list_json "$id" subnet)" \
        --argjson extra_domain "$(userlist_entries_json "$id" domains)" \
        --argjson extra_subnet "$(userlist_entries_json "$id" subnets)" \
        '{
            id: $id,
            title: $title,
            community_list: $community,
            domain: (($domain + $extra_domain) | unique),
            subnet: (($subnet + $extra_subnet + $community_subnet) | unique)
        }'
}

config_channel_json() {
    local id="$1"

    jq -nc \
        --arg id "$id" \
        --arg type "$(config_uci_get "$id" type)" \
        --argjson subscription "$(config_uci_list_json "$id" subscription)" \
        '{id: $id, type: (if $type == "" then "direct" else $type end), subscription: $subscription}'
}

# A binding pointing at something that does not exist is a warning and a skip,
# never a refusal: one mistyped name must not take the whole router down.
config_bindings_json() {
    local id profile channel result='[]' order

    for id in $(config_section_ids binding); do
        profile=$(config_uci_get "$id" profile)
        channel=$(config_uci_get "$id" channel)
        order=$(config_uci_get "$id" order)
        [ -n "$order" ] || order=100

        if [ -z "$profile" ] || [ -z "$channel" ]; then
            log_warn "привязка $id без профиля или канала, пропущена"
            continue
        fi
        if [ "$(config_uci_get "$profile" title)" = "" ] && [ -z "$(uci -q show "$XKOP_CONFIG.$profile" 2> /dev/null)" ]; then
            log_warn "привязка $id ссылается на несуществующий профиль $profile, пропущена"
            continue
        fi
        if [ -z "$(uci -q show "$XKOP_CONFIG.$channel" 2> /dev/null)" ]; then
            log_warn "привязка $id ссылается на несуществующий канал $channel, пропущена"
            continue
        fi

        result=$(printf '%s' "$result" | jq -c \
            --argjson order "$order" \
            --argjson profile "$(config_profile_json "$profile")" \
            --argjson channel "$(config_channel_json "$channel")" \
            '. + [{order: $order, profile: $profile, channel: $channel}]')
    done

    printf '%s' "$result"
}

config_input_json() {
    jq -nc \
        --argjson settings "$(config_settings_json)" \
        --argjson pool "$(subscription_pool_all)" \
        --argjson bindings "$(config_bindings_json)" \
        '{settings: $settings, pool: $pool, bindings: $bindings}'
}

config_engine_bin() {
    command -v "${XKOP_ENGINE_BIN:-xray}" 2> /dev/null || echo "${XKOP_ENGINE_BIN:-xray}"
}

# The engine decides, not us. Anything else is an opinion about a format that
# changes with every release.
config_validate() {
    local file="$1" engine
    engine=$(config_engine_bin)

    command -v "$engine" > /dev/null 2>&1 || return 2

    # The format is stated outright rather than left to the file name: the
    # engine guesses it from the extension, and a candidate written as
    # "config.json.new" is refused before it is even parsed.
    "$engine" run -test -format json -c "$file" > /dev/null 2>&1
}

# Generates, validates, installs. Returns 0 when a new configuration is in
# place, 1 when the old one was kept, 2 when there was nothing to install.
# Собрана ли конфигурация успешно.
#
# config_generate различает три исхода: 0 — установлена новая, 2 — прежняя
# годится и менять нечего, 1 — отказ. Вызывающие читали «всё, что не ноль»
# как отказ, и на каждый перезапуск в журнал уходило «новая конфигурация
# не принята» сразу после «конфигурация не изменилась». Две строки подряд,
# противоречащие друг другу, и вторая — неправда.
config_generated_ok() {
    case "$1" in
        0 | 2) return 0 ;;
        *) return 1 ;;
    esac
}

config_generate() {
    local new old
    mkdir -p "$XKOP_RUN_DIR" "$(dirname "$XKOP_CONFIG_PATH")"
    new="$XKOP_RUN_DIR/config.json.new"

    if ! config_input_json | jq -f "$XKOP_LIB_DIR/config.jq" > "$new" 2> "$XKOP_RUN_DIR/config.err"; then
        log_error "конфигурация не собралась: $(head -n 1 "$XKOP_RUN_DIR/config.err" 2> /dev/null)"
        return 1
    fi

    if ! config_validate "$new"; then
        case "$?" in
            2) log_warn "движок не найден, конфигурация не проверена и не установлена" ;;
            *) log_error "движок отверг новую конфигурацию, оставляю прежнюю" ;;
        esac
        return 1
    fi

    if [ -f "$XKOP_CONFIG_PATH" ] && cmp -s "$new" "$XKOP_CONFIG_PATH"; then
        log_info "конфигурация не изменилась"
        return 2
    fi

    old="$XKOP_CONFIG_PATH.previous"
    [ -f "$XKOP_CONFIG_PATH" ] && cp "$XKOP_CONFIG_PATH" "$old"
    cp "$new" "$XKOP_CONFIG_PATH.tmp" && mv "$XKOP_CONFIG_PATH.tmp" "$XKOP_CONFIG_PATH"
    log_info "конфигурация обновлена"
    return 0
}
