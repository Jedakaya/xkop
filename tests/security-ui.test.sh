#!/bin/sh
set -eu
ROOT=${ROOT:-$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)}
if command -v node >/dev/null 2>&1; then
    node "$ROOT/tests/security-ui.cjs"
else
    echo 'SKIP security UI: node unavailable'
fi
