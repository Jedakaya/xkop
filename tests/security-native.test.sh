#!/bin/sh
set -eu
ROOT=${ROOT:-$(dirname "$0")/..}
if [ -n "${XKOP_NATIVE_LAB:-}" ] && command -v python3 >/dev/null 2>&1; then
    python3 "$ROOT/tests/security_native.py"
else
    echo 'SKIP native security: explicit disposable OpenWrt rootfs lab required'
fi
