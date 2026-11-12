#!/bin/sh
# Disposable native test adapter; production code has no laboratory gate.
set -eu
[ "$(cat /lab/xkop-native-lab 2>/dev/null)" = 'DISPOSABLE OPENWRT ROOTFS' ] || exit 1
library=$(cd "$(dirname "$0")/../xkop/files/usr/lib/xkop" && pwd)
if [ "${1:-}" = start ] && [ ! -e /etc/xkop/fleet/transaction ]; then
    cp /lab/check-health "$library/fleet-health.sh"
    printf '{}\n' > /etc/xkop/fleet/health.json
    : > /etc/xkop/fleet/allow-install
fi
exec sh "$library/fleet-transaction.sh" "$@"
