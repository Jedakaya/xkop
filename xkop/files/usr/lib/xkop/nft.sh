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
#
# The chains are called mangle, mangle_output and proxy, the same names podkop
# uses, and that is not a matter of taste: "mark" and "output" are keywords in
# the nft grammar, and a chain named after one of them makes the parser fail on
# the declaration itself. Because the file is applied whole, that single line
# takes the entire ruleset with it - the router ends up with no rules at all
# and nothing to point at, since the error names a chain that looks perfectly
# ordinary.

nft_ruleset() {
    local interfaces="$1" excluded="$2" fakeip="${3:-0}" exclude_ntp="${4:-0}"
    local routed="${5:-}"
    local ifname_elements="" excluded_elements="" routed_elements=""

    for iface in $interfaces; do
        ifname_elements="$ifname_elements \"$iface\","
    done
    ifname_elements="${ifname_elements%,}"

    for address in $excluded; do
        excluded_elements="$excluded_elements $address,"
    done
    excluded_elements="${excluded_elements%,}"

    for address in $routed; do
        routed_elements="$routed_elements $address,"
    done
    routed_elements="${routed_elements%,}"

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

$(if [ -n "$routed_elements" ]; then
cat << ROUTED

    # Адреса, ради которых движок и нужен: поддельный диапазон и подсети
    # профилей. Всё остальное ядро отдаёт напрямую, не будя userspace.
    set routed4 {
        type ipv4_addr
        flags interval
        auto-merge
        elements = { $routed_elements }
    }
ROUTED
fi)

    chain mangle {
        type filter hook prerouting priority -150; policy accept;

        # Свой трафик движка не трогаем ни при каких условиях.
        meta mark & $XKOP_NFT_ENGINE_MARK == $XKOP_NFT_ENGINE_MARK return

        iifname != @interfaces return
        ip daddr @local4 return
        ip6 daddr @local6 return
$(if [ -n "$excluded_elements" ]; then echo "        ip saddr @excluded4 return"; fi)

$(if [ "$exclude_ntp" = "1" ]; then
cat << NTP
        # Синхронизация времени идёт мимо движка. Часы нужны раньше, чем
        # туннель: сертификат TLS проверяется по времени, и роутер с уехавшими
        # часами не может починить их через путь, которому сам не верит.
        udp dport 123 return
NTP
fi)
$(if [ -n "$routed_elements" ]; then
cat << PICK
        # Метится только то, что действительно маршрутизируется.
        #
        # Правило было одно: пометить весь трафик с LAN и отдать движку. Тогда
        # через userspace идёт и то, что уходит напрямую, - то есть весь
        # интернет, включая замер скорости. На двухъядерном роутере это
        # ощущается как «нестабильное соединение», хотя ничего не сломано.
        #
        # Так делает podkop, и это возможно ровно в режиме поддельных адресов:
        # маршрутизируемые имена уже получили адрес из своего диапазона, а
        # подсети профилей известны и так. По адресу видно, кого перехватывать.
        ip daddr @routed4 meta l4proto { tcp, udp } meta mark set $XKOP_NFT_MARK counter
PICK
else
cat << ALL
        # Имя видно только внутри соединения, поэтому через движок обязано
        # пройти всё: иначе распознавать нечего.
        meta l4proto { tcp, udp } meta mark set $XKOP_NFT_MARK counter
ALL
fi)
    }
$(if [ "$fakeip" = "1" ]; then
cat << FAKEIP

    # Traffic the router itself starts towards a fake address. The client
    # rules above never see it - it is not routed, it is generated here - and
    # without this the router cannot reach a name it faked for itself.
    chain mangle_output {
        type route hook output priority -150; policy accept;

        # Первым делом - собственный трафик движка.
        #
        # Без этого получается петля: движок отправляет соединение наружу,
        # правило ниже видит адрес из поддельного диапазона и заворачивает
        # пакет обратно в движок, тот отправляет снова. Тысячи соединений
        # за секунды, триста пятьдесят мегабайт памяти, OOM и перезагрузка
        # роутера. Ровно это и наблюдалось на железе.
        meta mark & $XKOP_NFT_ENGINE_MARK == $XKOP_NFT_ENGINE_MARK return

        ip daddr @local4 return
        meta mark & $XKOP_NFT_MARK == $XKOP_NFT_MARK return
        ip daddr $XKOP_FAKEIP_RANGE meta l4proto { tcp, udp } meta mark set $XKOP_NFT_MARK counter
    }
FAKEIP
fi)

    chain proxy {
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

# Адреса, ради которых стоит будить движок: поддельный диапазон плюс подсети
# всех профилей, привязанных к непрямым каналам. Ручные подсети, списки
# сообщества и списки по ссылке — всё это уже сведено в профиль.
# Только то, что nft точно примет: адрес IPv4 или подсеть IPv4.
#
# В набор идут подсети профилей, а туда попадает всё, что положил человек или
# отдал список по ссылке. Набор применяется одним файлом, целиком или никак,
# поэтому ОДНО негодное значение отменяет весь набор правил - и роутер
# остаётся без маршрутизации, продолжая раздавать клиентам поддельные адреса.
# Внешне это выглядит как «перезапустил движок, и всё умерло».
#
# Записано без регулярных выражений: та же причина, что и в jq-программах.
nft_valid_subnet() {
    local value="$1" addr prefix octet count=0

    case "$value" in
        *[!0-9./]*) return 1 ;;
        */*)
            addr="${value%%/*}"
            prefix="${value#*/}"
            case "$prefix" in
                '' | *[!0-9]* | *.*) return 1 ;;
            esac
            [ "$prefix" -le 32 ] || return 1
            ;;
        *) addr="$value" ;;
    esac

    IFS=. 
    for octet in $addr; do
        case "$octet" in
            '' | *[!0-9]*) unset IFS; return 1 ;;
        esac
        [ "$octet" -le 255 ] || { unset IFS; return 1; }
        count=$((count + 1))
    done
    unset IFS

    [ "$count" -eq 4 ]
}

nft_routed_addresses() {
    local id channel profile value dropped=0

    printf '%s
' "$XKOP_FAKEIP_RANGE"

    for id in $(config_section_ids binding 2> /dev/null); do
        channel=$(config_uci_get "$id" channel)
        [ -n "$channel" ] || continue
        [ "$(config_uci_get "$channel" type)" = "direct" ] && continue

        profile=$(config_uci_get "$id" profile)
        [ -n "$profile" ] || continue

        for value in $(config_profile_json "$profile" 2> /dev/null             | jq -r '.subnet[]?' 2> /dev/null); do
            if nft_valid_subnet "$value"; then
                printf '%s
' "$value"
            else
                dropped=$((dropped + 1))
            fi
        done
    done

    [ "$dropped" -gt 0 ]         && log_warn "в наборе перехвата пропущено негодных подсетей: $dropped" >&2

    return 0
}

nft_apply() {
    local interfaces excluded fakeip=0 exclude_ntp=0 routed=""

    [ "$(config_uci_get settings dns_mode 2> /dev/null)" = "fakeip" ] && fakeip=1
    [ "$(config_uci_get settings exclude_ntp 2> /dev/null)" = "1" ] && exclude_ntp=1

    # Выборочный перехват возможен только в режиме поддельных адресов: без него
    # имя видно лишь внутри соединения, и чтобы его прочесть, соединение
    # обязано пройти через движок.
    #
    # У выборочного перехвата есть цена, и она названа в интерфейсе: клиент,
    # который резолвит мимо роутера, поддельного адреса не получит, и его
    # трафик к заблокированному уйдёт напрямую. При сплошном перехвате движок
    # поймал бы такое по имени внутри соединения — ценой того, что через
    # userspace идёт весь интернет.
    if [ "$fakeip" = "1" ]         && [ "$(config_uci_get settings intercept 2> /dev/null)" != "all" ]; then
        routed=$(nft_routed_addresses)
    fi

    interfaces=$(subscription_config_list settings source_interface | tr '\n' ' ')
    [ -n "$(printf '%s' "$interfaces" | tr -d ' ')" ] || interfaces="br-lan"
    excluded=$(subscription_config_list settings excluded_source_ip | tr '\n' ' ')

    if ! command -v nft > /dev/null 2>&1; then
        log_error "nft не найден, правила не применены"
        return 1
    fi

    nft delete table inet "$XKOP_NFT_TABLE" 2> /dev/null || true

    if ! nft_ruleset "$interfaces" "$excluded" "$fakeip" "$exclude_ntp" "$routed"         | nft -f - 2> "$XKOP_RUN_DIR/nft.err"; then

        # Отказ набора — это роутер без маршрутизации, поэтому вторая попытка
        # без выборочного перехвата. Она проще: ни одного значения снаружи,
        # только наши собственные. Пусть через движок пойдёт лишнее — это
        # медленнее, но работает, а «ничего не работает» не лечится ничем.
        log_error "правила nft отвергнуты: $(head -n 1 "$XKOP_RUN_DIR/nft.err" 2> /dev/null)"

        if [ -n "$routed" ]; then
            log_warn "повторяю без выборочного перехвата"
            if nft_ruleset "$interfaces" "$excluded" "$fakeip" "$exclude_ntp" ""                 | nft -f - 2> "$XKOP_RUN_DIR/nft.err"; then
                nft_routing_rule
                log_info "правила nft применены без выборочного перехвата"
                return 0
            fi
            log_error "и без него отвергнуты: $(head -n 1 "$XKOP_RUN_DIR/nft.err" 2> /dev/null)"
        fi

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
