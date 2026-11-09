#!/bin/sh
# Linux integration: actual Xray SOCKS path, blocked direct download, real list validation.
set -eu
ROOT=${ROOT:-$(dirname "$0")/..}
export ROOT XRAY="${XRAY:-xray}"
if [ "$(uname -s)" != Linux ] || ! command -v "$XRAY" >/dev/null 2>&1 \
    || ! command -v python3 >/dev/null 2>&1; then
    echo 'skip live bootstrap integration: Linux, Python and Xray required'
    exit 0
fi
python3 "$ROOT/tests/bootstrap_live.py"
