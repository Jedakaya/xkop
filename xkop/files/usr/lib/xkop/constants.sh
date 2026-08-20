#!/bin/sh
# shellcheck shell=ash
# Shared constants. Replaced at package build time, see the Makefile.

XKOP_VERSION='__COMPILED_VERSION_VARIABLE__'

XKOP_LIB_DIR='/usr/lib/xkop'
XKOP_CONFIG='xkop'

# Engine binary name, used for the "is it even running" question.
XKOP_ENGINE_BIN='xray'

# Xray metrics endpoint. The port is configurable because a router may already
# have something on it; the address is not, the endpoint is unauthenticated and
# has no business being reachable from outside the router.
XKOP_METRICS_HOST='127.0.0.1'
XKOP_METRICS_PORT_DEFAULT='11111'
XKOP_METRICS_PATH='/debug/vars'
XKOP_METRICS_TIMEOUT='3'
