#!/bin/sh
# shellcheck shell=ash
# User lists: domains and subnets a profile pulls from a URL or reads from a
# file on the router.
#
# These are not the community lists - those live in geosite.dat and the engine
# resolves them itself. These are the ones a person maintains: a file with the
# subnets of a bank, a URL with a list someone else publishes.
#
# Downloaded copies are cached on the persistent partition and are the source
# of truth at start, exactly like a subscription: a router with no internet
# must come up with the rules it had yesterday rather than with none.

XKOP_USERLIST_DIR="$XKOP_STATE_DIR/lists"

# A stable file name for a URL without needing to store the URL anywhere: the
# same address always maps to the same file, and a changed address simply
# becomes a different one.
userlist_cache_path() {
    printf '%s/%s.lst' "$XKOP_USERLIST_DIR" "$(printf '%s' "$1" | md5sum | cut -c1-16)"
}

# Lines that are neither empty nor comments. A list is trusted only as far as
# it parses: a page of HTML from a captive portal must not become a routing
# rule, so anything that does not look like a domain or a subnet is dropped
# and counted rather than passed on.
userlist_clean_domains() {
    tr -d '\r' < "$1" \
        | sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | grep -v '^$' \
        | grep -E '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$'
}

userlist_clean_subnets() {
    tr -d '\r' < "$1" \
        | sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | grep -v '^$' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$'
}

# Список может приехать не строками, а документом JSON.
#
# Официальные списки отдаются именно так, и у каждого своя форма: Fastly
# кладёт адреса в {"addresses": [...]}, Google - в {"prefixes":
# [{"ipv4Prefix": ...}]}, набор правил sing-box - в {"rules": [{"ip_cidr":
# [...]}]}. Угадывать каждую форму незачем и вредно: берём из документа
# все строки подряд, а дальше работает та же проверка, что и для обычного
# файла, - в правило попадёт только похожее на подсеть или на имя.
#
# Это ровно то место, где живой роутер упёрся: адреса Fastly пришлось
# вписывать руками, потому что подключить их ссылкой было нельзя. podkop
# разбирает только свой формат правил sing-box, остальное у него тоже
# переписывается руками.
userlist_flatten_json() {
    local file="$1"

    case "$(head -c 200 "$file" 2> /dev/null | tr -d '[:space:]' | cut -c1)" in
        '{' | '[') ;;
        *) return 1 ;;
    esac

    # Через файл, а не через переменную: список подсетей целого CDN - это
    # десятки тысяч строк, и держать их в памяти оболочки на роутере незачем.
    if ! jq -r '[.. | strings] | .[]' "$file" > "$file.flat" 2> /dev/null; then
        rm -f "$file.flat"
        return 1
    fi

    if [ ! -s "$file.flat" ]; then
        rm -f "$file.flat"
        return 1
    fi

    mv "$file.flat" "$file"
}

# Downloads into RAM, checks it parses into something, and only then replaces
# the cached copy. A list that arrived as an error page leaves yesterday's
# rules in place.
userlist_fetch() {
    local url="$1" kind="$2" target tmp count
    target=$(userlist_cache_path "$url")
    mkdir -p "$XKOP_USERLIST_DIR" "$XKOP_RUN_DIR"
    tmp="$XKOP_RUN_DIR/userlist.$$"

    if ! lists_download "$url" "$tmp" 60; then
        log_warn "список не скачался: $url"
        rm -f "$tmp"
        return 1
    fi

    userlist_flatten_json "$tmp"

    if [ "$kind" = "subnets" ]; then
        count=$(userlist_clean_subnets "$tmp" | wc -l | tr -d ' ')
    else
        count=$(userlist_clean_domains "$tmp" | wc -l | tr -d ' ')
    fi

    if [ "${count:-0}" -eq 0 ]; then
        log_warn "в списке нет ни одной пригодной строки, оставляю прежний: $url"
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$target"
    log_info "список обновлён: $url, строк $count"
    return 0
}

# Everything a profile refers to, as lines. Sources that are missing are
# skipped with a warning: one unreachable list must not take the routing down.
userlist_entries() {
    local profile="$1" kind="$2" option_remote option_local path url

    if [ "$kind" = "subnets" ]; then
        option_remote=remote_subnets
        option_local=local_subnets
    else
        option_remote=remote_domains
        option_local=local_domains
    fi

    subscription_config_list "$profile" "$option_remote" 2> /dev/null | while IFS= read -r url; do
        [ -n "$url" ] || continue
        path=$(userlist_cache_path "$url")
        if [ ! -s "$path" ]; then
            log_warn "списка ещё нет в кэше: $url"
            continue
        fi
        if [ "$kind" = "subnets" ]; then
            userlist_clean_subnets "$path"
        else
            userlist_clean_domains "$path"
        fi
    done

    subscription_config_list "$profile" "$option_local" 2> /dev/null | while IFS= read -r path; do
        [ -n "$path" ] || continue
        if [ ! -s "$path" ]; then
            log_warn "локального списка нет: $path"
            continue
        fi
        if [ "$kind" = "subnets" ]; then
            userlist_clean_subnets "$path"
        else
            userlist_clean_domains "$path"
        fi
    done
}

userlist_entries_json() {
    userlist_entries "$1" "$2" | sort -u | jq -R -s -c 'split("\n") | map(select(. != ""))'
}

# Refresh of everything every profile refers to. Called on the same schedule as
# the community lists.
userlist_update_all() {
    local profile url updated=0 failed=0

    for profile in $(config_section_ids profile); do
        for url in $(subscription_config_list "$profile" remote_domains 2> /dev/null); do
            if userlist_fetch "$url" domains; then updated=$((updated + 1)); else failed=$((failed + 1)); fi
        done
        for url in $(subscription_config_list "$profile" remote_subnets 2> /dev/null); do
            if userlist_fetch "$url" subnets; then updated=$((updated + 1)); else failed=$((failed + 1)); fi
        done
    done

    jq -nc --argjson updated "$updated" --argjson failed "$failed" \
        '{ok: ($failed == 0), updated: $updated, failed: $failed}'
}
