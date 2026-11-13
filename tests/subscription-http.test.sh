#!/bin/sh
set -eu
ROOT=${ROOT:-$(dirname "$0")/..}
command -v python3 >/dev/null 2>&1 || { echo 'skip real HTTP subscription tests: python3 required'; exit 0; }
python3 "$ROOT/tests/subscription_http.py"
