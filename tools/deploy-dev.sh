#!/bin/sh
# Puts the working copy on a router without building a package.
#
# For iterating on hardware: a package build takes minutes and a tag, while a
# shell change needs neither. The installed package stays untouched otherwise -
# this only overwrites the files it copies.
#
# Usage:
#   tools/deploy-dev.sh root@192.168.1.1
#   tools/deploy-dev.sh root@192.168.1.1 --config    и /etc/config/xkop тоже
#
# The router configuration is NOT overwritten unless --config is given: it is
# the one file on the router that holds state we did not put there.

set -eu

ROOT=$(dirname "$0")/..
TARGET=${1:-${XKOP_ROUTER:-}}
WITH_CONFIG=${2:-}

if [ -z "$TARGET" ]; then
    echo "укажите роутер: tools/deploy-dev.sh root@192.168.1.1" >&2
    exit 2
fi

echo "== $TARGET"

ssh "$TARGET" 'mkdir -p /usr/lib/xkop'

scp "$ROOT"/xkop/files/usr/lib/xkop/* "$TARGET:/usr/lib/xkop/"
scp "$ROOT"/xkop/files/usr/bin/xkop "$TARGET:/usr/bin/xkop"
scp "$ROOT"/xkop/files/etc/init.d/xkop "$TARGET:/etc/init.d/xkop"

if [ "$WITH_CONFIG" = "--config" ]; then
    echo "-- /etc/config/xkop тоже"
    scp "$ROOT"/xkop/files/etc/config/xkop "$TARGET:/etc/config/xkop"
fi

# The package build substitutes the version; a hand copy has none, and saying
# "dev" is better than shipping the placeholder into the interface.
ssh "$TARGET" 'chmod +x /usr/bin/xkop /etc/init.d/xkop && sed -i "s/__COMPILED_VERSION_VARIABLE__/dev/" /usr/lib/xkop/constants.sh'

echo "-- проверка:"
ssh "$TARGET" 'xkop version'
