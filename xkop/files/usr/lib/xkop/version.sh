#!/bin/sh
# shellcheck shell=ash
# Engine version comparison and the capability table built on top of it.
#
# Routers in the field run different Xray versions, and a configuration the
# installed engine rejects means no engine at all - that is a dead router. So a
# version dependent feature is switched on by this table, never by assumption.
# See docs/install.md.
#
# Comparison is done by hand rather than with "sort -V": busybox sort does not
# carry that option everywhere, and a silently wrong comparison here disables
# working features or, worse, enables broken ones.

# Strips the leading v and everything from the first non-version character on,
# so "v26.1.23-r2" and "26.1.23" compare the same.
version_normalize() {
    printf '%s' "$1" | sed -e 's/^[vV]//' -e 's/[^0-9.].*$//' -e 's/\.$//'
}

# One dotted component as a plain number. Missing component is zero, leading
# zeros are stripped: "08" would otherwise be read as invalid octal.
version_part() {
    local value
    value=$(printf '%s' "$1" | cut -d. -f"$2")
    value=$(printf '%s' "$value" | sed -e 's/[^0-9]//g' -e 's/^0*//')
    [ -n "$value" ] || value=0
    printf '%s' "$value"
}

# True when $1 is at least $2. Compares up to four components.
version_ge() {
    local left right index left_part right_part

    left=$(version_normalize "$1")
    right=$(version_normalize "$2")

    index=1
    while [ "$index" -le 4 ]; do
        left_part=$(version_part "$left" "$index")
        right_part=$(version_part "$right" "$index")

        [ "$left_part" -gt "$right_part" ] && return 0
        [ "$left_part" -lt "$right_part" ] && return 1

        index=$((index + 1))
    done

    return 0
}

# Minimum engine version per capability.
#
# Hysteria 2 outbound and transport landed in v26.1.23, confirmed by the
# release notes of that tag. Capabilities whose boundary is not established -
# ECH, post-quantum VLESS - are deliberately absent: guessing a boundary either
# disables something that works or emits a configuration the engine rejects.
XKOP_MIN_VERSION_HYSTERIA2='26.1.23'

# 0 - supported, 1 - too old, 2 - boundary unknown.
#
# The third answer exists so that a caller cannot mistake "we never established
# this" for "not supported". What to do about it is the caller's decision.
engine_supports() {
    local capability="$1" version="$2" required

    case "$capability" in
        hysteria2) required="$XKOP_MIN_VERSION_HYSTERIA2" ;;
        *) return 2 ;;
    esac

    [ -n "$version" ] || return 2

    if version_ge "$version" "$required"; then
        return 0
    fi

    return 1
}
