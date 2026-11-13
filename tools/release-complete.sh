#!/bin/sh
# CI tooling only; Python is not added to router dependencies.
set -eu
exec python3 "$(dirname "$0")/release-metadata.py" "$@"
