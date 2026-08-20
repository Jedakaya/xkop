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

# Control interface of the engine: which node the balancer is on, and pinning
# it to one. Loopback only, unauthenticated by design.
XKOP_API_PORT_DEFAULT='11112'

# Runtime addresses. xkop and podkop are not meant to run side by side - the
# package declares the conflict - but the numbers are deliberately different
# from podkop's anyway. On a router migrated from it, a leftover rule or a
# stale dnsmasq entry must be recognizable at a glance instead of quietly
# looking like ours.
XKOP_DNS_INBOUND_ADDRESS='127.0.0.43'
XKOP_DNS_INBOUND_PORT='53'
XKOP_TPROXY_ADDRESS='127.0.0.1'
XKOP_TPROXY_PORT='1608'
XKOP_FAKEIP_RANGE='198.18.0.0/15'

XKOP_NFT_TABLE='xkop'
XKOP_NFT_MARK='0x00200000'

# Метка собственного трафика движка.
#
# Без неё получается петля: движок отправляет соединение наружу, правило
# в цепочке вывода видит адрес из поддельного диапазона и заворачивает пакет
# обратно в движок. Тот отправляет снова — и так тысячи соединений за секунды,
# триста пятьдесят мегабайт памяти, OOM, мёртвая админка и перезагрузка.
#
# Движок ставит эту метку на свои исходящие сокеты (sockopt.mark), а правила
# такой трафик пропускают не глядя. Значение отдельное от XKOP_NFT_MARK: одна
# метка отвечает на вопрос «это надо перехватить», другая — «это мы сами».
XKOP_NFT_ENGINE_MARK='0x00400000'
XKOP_NFT_ENGINE_MARK_DEC='4194304'

XKOP_ROUTE_TABLE='106'

# Reserved outbound tags. The stats command derives traffic roles from them and
# the configuration generator must not invent others - see docs/stats.md.
XKOP_OUTBOUND_DIRECT='direct'
XKOP_OUTBOUND_BLOCK='block'
XKOP_OUTBOUND_DNS='dns-out'
XKOP_OUTBOUND_METRICS='metrics-out'

# Persistent state. The subscription cache has to survive a reboot: a router
# without internet must still come up routing, and for that the last usable
# payload is the source of truth - see docs/subscription.md.
XKOP_STATE_DIR='/etc/xkop'
XKOP_CACHE_DIR='/etc/xkop/cache'
XKOP_RUN_DIR='/tmp/xkop'
XKOP_CONFIG_PATH='/etc/xkop/config.json'

# Access log: one line per connection, with the outbound the engine chose.
# This is what makes route explanation an observation rather than a guess.
# It lives in RAM and is trimmed on a schedule - unbounded it would fill /tmp
# on a busy network within a day.
XKOP_ACCESS_LOG='/tmp/xkop/access.log'
XKOP_ACCESS_LOG_MAX_KB='2048'

# Loopback-only socks inbound used by the explain command to ask the engine
# what it would do with a name, by actually making it do it.
XKOP_PROBE_PORT='10809'

# Client panel. The port is deliberately not podkop's 8080: a router migrated
# from it may still have that one taken, and two panels answering on the same
# port is a confusion nobody needs while debugging.
XKOP_PANEL_ROOT='/www-xkop'
XKOP_PANEL_PORT='8090'
XKOP_PANEL_SECTION='xkop_panel'
