#!/bin/sh
set -eu
ROOT=${ROOT:-$(dirname "$0")/..}
sh -c 'exec 7</dev/null 9</dev/null; . "$1"; [ ! -e /proc/self/fd/7 ] && [ ! -e /proc/self/fd/9 ]' \
    sh "$ROOT/xkop/files/etc/init.d/xkop" || { echo 'FAIL init inherited package transaction descriptors'; exit 1; }
echo 'ok init closes inherited package locks'
