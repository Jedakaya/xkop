#!/bin/sh
# shellcheck shell=ash
# Logging.
#
# Human readable text goes to the log and never to stdout: the client panel and
# LuCI parse what commands print, and a stray sentence in the middle of JSON
# breaks them. See docs/cli-contract.md.

log_write() {
    local level="$1" message="$2"

    if command -v logger > /dev/null 2>&1; then
        logger -t xkop -p "daemon.$level" "$message"
    fi

    # Off a router, and whenever someone is watching, the same line goes to
    # stderr - which is not stdout and therefore not part of any contract.
    if [ -n "${XKOP_VERBOSE:-}" ] || ! command -v logger > /dev/null 2>&1; then
        echo "[$level] $message" >&2
    fi
}

log_info() { log_write info "$1"; }
log_warn() { log_write warn "$1"; }
log_error() { log_write err "$1"; }
