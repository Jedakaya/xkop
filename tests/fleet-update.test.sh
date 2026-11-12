#!/bin/sh
# Optional integration dependency is a test tool, not a new Xkop dependency.
set -eu
ROOT=${ROOT:-$(dirname "$0")/..}
if [ "$(uname -s)" != Linux ] || ! command -v usign >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    echo 'skip signed update HTTPS integration: Linux, Python and usign required'
    exit 0
fi
python3 "$ROOT/tests/fleet_update_https.py" -v
