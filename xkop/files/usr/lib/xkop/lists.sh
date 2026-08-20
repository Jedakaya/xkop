#!/bin/sh
# shellcheck shell=ash
# Lists of domains the routing rules refer to.
#
# The engine resolves "geosite:russia-inside" when it loads the configuration,
# and without the file it refuses the whole configuration - not the one rule.
# So the list is a hard dependency of a working router, and it is treated like
# one: downloaded into RAM, proven by the engine itself, and only then put on
# flash.
#
# The file comes from itdoginfo/allow-domains and is about 90 KB, against the
# ten megabytes of the standard geosite.dat. That difference is the whole
# reason it is worth having on a router.

XKOP_ASSET_DIR='/usr/share/xray'
XKOP_GEOSITE_URL='https://github.com/itdoginfo/allow-domains/releases/latest/download/geosite.dat'

# A category known to be in that file. Used to prove a downloaded copy is
# actually loadable before it replaces the working one.
XKOP_GEOSITE_PROBE='russia-inside'

# Загрузка списка: сначала напрямую, потом через движок.
#
# Списки живут на GitHub, а он у части провайдеров недоступен ровно тогда,
# когда роутер и нужен. Туннель при этом уже работает - им и пользуемся:
# у движка есть локальный socks на петле, тот самый, через который ходит
# разбор маршрута. Своего адреса он наружу не отдаёт, отдельного порта
# не требует и появляется вместе с движком.
#
# Порядок именно такой: прямая загрузка дешевле и не зависит от того, поднялся
# ли движок. Через туннель - только когда прямая не вышла, и об этом сказано
# в журнале, чтобы «списки обновились» не скрывало, каким путём.
lists_download() {
    local url="$1" target="$2" timeout="${3:-60}"

    curl -fsSL --max-time "$timeout" -o "$target" "$url" 2> /dev/null && return 0

    command -v xray > /dev/null 2>&1 || return 1
    engine_answers 2> /dev/null || return 1

    if curl -fsSL --max-time "$timeout" \
        --socks5-hostname "127.0.0.1:${XKOP_PROBE_PORT:-10809}" \
        -o "$target" "$url" 2> /dev/null; then
        log_info "список взят через движок: напрямую не отдался"
        return 0
    fi

    return 1
}

lists_geosite_path() {
    printf '%s/geosite.dat' "$XKOP_ASSET_DIR"
}

# Subnets of the community lists.
#
# geosite.dat holds names and nothing else, and a whole class of services is
# not reachable by name at all: the Telegram client goes to hardcoded
# addresses, and so do Discord voice, Meta and the ASN lists. Adding such a
# list to a profile and getting no change is not a mystery - there was never
# anything for a domain rule to match.
#
# sing-box gets both halves in one .srs file, which is why the same lists work
# there without any of this. For us the addresses live separately, as plain
# text, and they are turned into "ip" entries of the same routing rule the
# domains produce.
XKOP_SUBNET_BASE='https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4'

# Категории, у которых подсети есть. Список закрытый намеренно: имени файла
# для остальных в репозитории нет, и попытка скачать его каждый раз даёт 404
# и запись в журнале, которая выглядит как поломка.
XKOP_SUBNET_LISTS='telegram discord meta twitter cloudflare cloudfront digitalocean google_meet hetzner ovh roblox'

lists_subnet_dir() {
    printf '%s/subnets' "$XKOP_CACHE_DIR"
}

# geosite пишет имена через дефис, файлы подсетей - через подчёркивание.
lists_subnet_name() {
    printf '%s' "$1" | tr '-' '_'
}

lists_subnet_has() {
    local name entry
    name=$(lists_subnet_name "$1")
    for entry in $XKOP_SUBNET_LISTS; do
        [ "$entry" = "$name" ] && return 0
    done
    return 1
}

lists_subnet_path() {
    printf '%s/%s.lst' "$(lists_subnet_dir)" "$(lists_subnet_name "$1")"
}

# Одна категория. Кэш - источник истины: неудачная загрузка не имеет права
# ухудшить то, что уже работает.
lists_subnet_fetch() {
    local category="$1" name target tmp

    lists_subnet_has "$category" || return 0

    name=$(lists_subnet_name "$category")
    target=$(lists_subnet_path "$category")
    mkdir -p "$(lists_subnet_dir)" "$XKOP_RUN_DIR"
    tmp="$XKOP_RUN_DIR/subnet-$name.lst"

    if ! lists_download "$XKOP_SUBNET_BASE/$name.lst" "$tmp" 60; then
        [ -s "$target" ] && return 0
        log_warn "подсети списка $category не скачались"
        return 1
    fi

    # Пустой ответ и страница ошибки - не список. Проверяется тем же способом,
    # что и пользовательские списки: в файле должна быть хоть одна подсеть.
    if ! grep -q '^[0-9][0-9.]*/[0-9]' "$tmp" 2> /dev/null; then
        rm -f "$tmp"
        [ -s "$target" ] && return 0
        log_warn "в ответе для $category подсетей нет, файл не взят"
        return 1
    fi

    mv "$tmp" "$target"
    return 0
}

# Подсети категории из кэша, по одной в строке.
lists_subnet_entries() {
    local target
    target=$(lists_subnet_path "$1")
    [ -s "$target" ] || return 0
    grep '^[0-9][0-9.]*/[0-9]' "$target" 2> /dev/null
}

# Обновление подсетей всех категорий, упомянутых хоть в одном профиле.
lists_subnets_update() {
    local profile category
    command -v uci > /dev/null 2>&1 || return 0

    for profile in $(uci -q show "$XKOP_CONFIG" 2> /dev/null \
        | sed -n "s/^$XKOP_CONFIG\.\([^.]*\)=profile$/\1/p"); do
        for category in $(uci -q get "$XKOP_CONFIG.$profile.community_list" 2> /dev/null); do
            lists_subnet_fetch "$category"
        done
    done
    return 0
}

lists_present() {
    [ -s "$(lists_geosite_path)" ]
}

# The engine decides whether the file is good, the same way it decides about a
# configuration. A truncated download parses as a file and fails as a list.
lists_validate() {
    local candidate="$1" dir engine probe
    engine=$(config_engine_bin)
    command -v "$engine" > /dev/null 2>&1 || return 2

    dir="$XKOP_RUN_DIR/assets"
    rm -rf "$dir"
    mkdir -p "$dir"
    cp "$candidate" "$dir/geosite.dat" || return 1

    probe="$XKOP_RUN_DIR/geosite-probe.json"
    jq -nc --arg category "geosite:$XKOP_GEOSITE_PROBE" \
        '{log: {loglevel: "error"},
          outbounds: [{tag: "direct", protocol: "freedom"}],
          routing: {rules: [{type: "field", domain: [$category], outboundTag: "direct"}]}}' \
        > "$probe"

    XRAY_LOCATION_ASSET="$dir" "$engine" run -test -format json -c "$probe" > /dev/null 2>&1
}

# Пора ли обновлять список по настройке lists_update_interval. Настройка
# существовала и не читалась никем: список качался по расписанию cron, а
# значение в конфигурации выглядело действующим. Теперь оно и решает.
lists_due() {
    local interval age target now mtime

    target=$(lists_geosite_path)
    [ -f "$target" ] || return 0

    interval=$(config_uci_get settings lists_update_interval 2> /dev/null)
    [ -n "$interval" ] || interval="1d"
    age=$(subscription_interval_seconds "$interval")
    [ -n "$age" ] && [ "$age" -gt 0 ] || return 0

    now=$(date +%s 2> /dev/null)
    mtime=$(date -r "$target" +%s 2> /dev/null)
    case "$now$mtime" in
        '' | *[!0-9]*) return 0 ;;
    esac

    [ "$((now - mtime))" -ge "$age" ]
}

lists_update() {
    local tmp size_kb free_kb target
    target=$(lists_geosite_path)
    mkdir -p "$XKOP_RUN_DIR" "$XKOP_ASSET_DIR"

    if [ "${1:-}" != "force" ] && ! lists_due; then
        return 2
    fi

    # RAM first: a failed download must cost no flash and leave the working
    # list exactly where it was.
    tmp="$XKOP_RUN_DIR/geosite.dat"
    if ! lists_download "$XKOP_GEOSITE_URL" "$tmp" 120; then
        log_warn "список доменов не скачался, остаётся прежний"
        return 1
    fi

    if ! lists_validate "$tmp"; then
        case "$?" in
            2) log_warn "движка нет, список не проверен и не установлен" ;;
            *) log_error "скачанный список движок не принял, остаётся прежний" ;;
        esac
        rm -f "$tmp"
        return 1
    fi

    if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
        rm -f "$tmp"
        return 2
    fi

    size_kb=$(( ($(wc -c < "$tmp") + 1023) / 1024 ))
    free_kb=$(df -k "$XKOP_ASSET_DIR" | awk 'NR==2 {print $4}')
    if [ -n "$free_kb" ] && [ "$free_kb" -lt "$size_kb" ]; then
        log_error "не хватает места под список: нужно ${size_kb} КБ, свободно ${free_kb} КБ"
        rm -f "$tmp"
        return 1
    fi

    cp "$tmp" "$target.tmp" && mv "$target.tmp" "$target"
    rm -f "$tmp"
    log_info "список доменов обновлён, ${size_kb} КБ"
    return 0
}

# Состояние списков: что лежит на диске и насколько оно свежее.
#
# «Списки есть» отвечало на другой вопрос. Настоящий звучит так: скачались ли
# они все, и когда. Категория, выбранная в профиле, но не приехавшая, — это
# сайты, которые молча идут мимо туннеля, и заметить это иначе нечем.
lists_status_json() {
    local target used category file entries updated

    target=$(lists_geosite_path)
    used=$(uci -q show "$XKOP_CONFIG" 2> /dev/null \
        | sed -n "s/^$XKOP_CONFIG\.[^.]*\.community_list='\{0,1\}\(.*\)'\{0,1\}$/\1/p" \
        | tr -d "'" | tr ' ' '\n' | sort -u | grep -v '^$')

    {
        printf '['
        local first=1
        for category in $used; do
            lists_subnet_has "$category" || continue
            file=$(lists_subnet_path "$category")
            entries=$(lists_subnet_entries "$category" | grep -c . 2> /dev/null)
            [ -n "$entries" ] || entries=0
            updated=$(date -r "$file" +%s 2> /dev/null)
            [ -n "$updated" ] || updated=0
            [ "$first" -eq 1 ] || printf ','
            first=0
            jq -nc --arg c "$category" --argjson e "$entries" --argjson u "$updated" \
                '{category: $c, subnets: $e, updated: (if $u == 0 then null else $u end),
                  ready: ($e > 0)}'
        done
        printf ']'
    } > "$XKOP_RUN_DIR/subnet-status.json" 2> /dev/null

    jq -nc \
        --argjson geosite_present "$([ -s "$target" ] && echo true || echo false)" \
        --argjson geosite_size "$(wc -c < "$target" 2> /dev/null || echo 0)" \
        --argjson geosite_updated "$(date -r "$target" +%s 2> /dev/null || echo 0)" \
        --argjson subnets "$(cat "$XKOP_RUN_DIR/subnet-status.json" 2> /dev/null || echo '[]')" \
        --argjson categories "$(printf '%s' "$used" | jq -R -s -c 'split("\n") | map(select(. != ""))')" \
        '{
            ok: true,
            geosite: {
                present: $geosite_present,
                size_bytes: $geosite_size,
                updated: (if $geosite_updated == 0 then null else $geosite_updated end)
            },
            categories: $categories,
            subnets: $subnets,
            missing: [ $subnets[] | select(.ready | not) | .category ]
        }'
}
