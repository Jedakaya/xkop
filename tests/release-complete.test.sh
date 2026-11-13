#!/bin/sh
set -eu
ROOT=${ROOT:-$(dirname "$0")/..}
python3 "$ROOT/tests/release_metadata.py" -v
