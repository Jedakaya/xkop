#!/bin/sh
# This suite must never infer a live router as its target.
set -eu
if [ -z "${XKOP_NATIVE_LAB:-}" ]; then
    echo 'skip native APK/opkg transactions: explicit disposable OpenWrt rootfs lab required'
    exit 0
fi
python3 "${ROOT:-$(dirname "$0")/..}/tests/fleet_native.py" -v
