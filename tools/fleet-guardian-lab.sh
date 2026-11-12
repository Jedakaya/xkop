#!/bin/sh
# Test adapter: all watchdog/recovery logic belongs to the packaged supervisor.
set -eu
[ "$(cat /lab/xkop-native-lab 2>/dev/null)" = 'DISPOSABLE OPENWRT ROOTFS' ] || exit 1
source_library="$(dirname "$0")/../xkop/files/usr/lib/xkop"
library=/etc/xkop/fleet/supervisor/runtime/lib
if [ ! -f "$library/fleet-guardian.sh" ]; then
    mkdir -p "$library"
    cp "$source_library"/fleet-*.sh "$source_library/fleet-manifest.jq" "$library/"
    cp /lab/check-health "$library/fleet-health.sh"
fi
if [ "${1:-}" = queue ]; then
    printf '{}\n' > /etc/xkop/fleet/health.json
    : > /etc/xkop/fleet/allow-install
    set -- "$@" ffffffffffffffffffffffffffffffff
fi
exec sh "$library/fleet-guardian.sh" "$@"
