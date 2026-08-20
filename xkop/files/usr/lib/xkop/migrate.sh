#!/bin/sh
# shellcheck shell=ash
# Перенос пользовательских списков из podkop.
#
# У человека, настраивавшего podkop годами, в списках лежат три десятка
# доменов и подсетей — вбитых руками, по одному, по мере того как что-то
# не открывалось. Заставлять вводить это заново при переходе значит потерять
# половину: часть он просто не вспомнит.
#
# Переносятся только пользовательские списки — домены и подсети. Всё
# остальное (категории, резолвер, подписка) настраивается заново осознанно:
# молча перенесённая наполовину настройка хуже непереносённой, потому что
# выглядит настроенной.
#
# Вызывается установщиком до того, как podkop будет удалён, — после удаления
# переносить уже нечего.

XKOP_MIGRATE_CONFIG=${XKOP_MIGRATE_CONFIG:-podkop}

migrate_podkop_present() {
    [ -n "$(uci -q show "$XKOP_MIGRATE_CONFIG" 2> /dev/null)" ]
}

# Секции podkop, у которых вообще бывают пользовательские списки.
migrate_podkop_sections() {
    uci -q show "$XKOP_MIGRATE_CONFIG" 2> /dev/null \
        | sed -n "s/^$XKOP_MIGRATE_CONFIG\.\([^.=]*\)=section$/\1/p"
}

# Поддельные адреса не переносятся.
#
# В списке подсетей живого podkop лежали записи вида 198.18.2.109 — это
# не сети, а выданные когда-то FakeIP-адреса, попавшие в список вместе
# с настоящими. У нас свой пул поддельных адресов, и чужие в правилах
# означают перехват того, чего не существует.
migrate_podkop_subnet_ok() {
    case "$1" in
        198.18.* | 198.19.*) return 1 ;;
    esac
    printf '%s' "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$'
}

migrate_podkop_domain_ok() {
    printf '%s' "$1" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$'
}

# Домены и подсети из всех секций, по одному в строке, без повторов.
migrate_podkop_domains() {
    local id entry
    for id in $(migrate_podkop_sections); do
        for entry in $(uci -q get "$XKOP_MIGRATE_CONFIG.$id.user_domains" 2> /dev/null); do
            migrate_podkop_domain_ok "$entry" && printf '%s\n' "$entry"
        done
    done | sort -u
}

migrate_podkop_subnets() {
    local id entry
    for id in $(migrate_podkop_sections); do
        for entry in $(uci -q get "$XKOP_MIGRATE_CONFIG.$id.user_subnets" 2> /dev/null); do
            migrate_podkop_subnet_ok "$entry" && printf '%s\n' "$entry"
        done
    done | sort -u
}

# Сколько записей отброшено как поддельные адреса — это надо показать, а не
# проглотить: человек помнит, сколько у него было строк.
migrate_podkop_skipped() {
    local id entry count=0
    for id in $(migrate_podkop_sections); do
        for entry in $(uci -q get "$XKOP_MIGRATE_CONFIG.$id.user_subnets" 2> /dev/null); do
            migrate_podkop_subnet_ok "$entry" || count=$((count + 1))
        done
    done
    printf '%s' "$count"
}

# Переносит в профиль. Списки заменяются целиком, а не дополняются: повторный
# запуск обязан давать тот же результат, а не удваивать записи.
#
# Возвращает 1, когда переносить нечего, — установщику это нужно, чтобы
# не писать «перенесено 0 записей» на роутере, где podkop и не стоял.
migrate_podkop_apply() {
    local profile="${1:-blocked_ru}" entry domains subnets count=0

    migrate_podkop_present || return 1

    domains=$(migrate_podkop_domains)
    subnets=$(migrate_podkop_subnets)
    [ -n "$domains" ] || [ -n "$subnets" ] || return 1

    uci -q delete "$XKOP_CONFIG.$profile.domain"
    uci -q delete "$XKOP_CONFIG.$profile.subnet"

    for entry in $domains; do
        uci add_list "$XKOP_CONFIG.$profile.domain=$entry"
        count=$((count + 1))
    done
    for entry in $subnets; do
        uci add_list "$XKOP_CONFIG.$profile.subnet=$entry"
        count=$((count + 1))
    done

    uci commit "$XKOP_CONFIG"
    printf '%s' "$count"
}
