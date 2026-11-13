#!/bin/sh
# shellcheck shell=ash disable=SC2034,SC1091
# Exercise the installer engine branch without changing the host system.
set -eu
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
awk '/^[ ]*ENGINE_HAVE=/ {copy=1} /^[ ]*if download "\$XKOP_URL"/ {copy=0} copy' "$ROOT/install.sh" > "$work/branch"
note() { printf 'NOTE %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
engine_version() { printf '%s' "$HAVE"; }
engine_pkg_version() { printf '%s' "$HAVE"; }
engine_version_core() { printf '%s' "$1"; }
engine_url_version() { [ -z "$1" ] || printf '26.10.31'; }
download() { printf 'DOWNLOAD %s\n' "$1"; return 1; }
ARCH=aarch64-cortex-a53
WORK="$work"
XKOP_NO_ENGINE=0
for FORMAT in apk ipk; do
    HAVE=26.10.31
    ENGINE_URL=https://example.net/engine
    ( . "$work/branch" ) > "$work/same"
    if grep -qE 'WARN|DOWNLOAD' "$work/same"; then
        echo "FAIL $FORMAT: installed engine incorrectly reported missing"; exit 1
    fi
    HAVE=26.9.9
    ( . "$work/branch" ) > "$work/old"
    grep -q '^DOWNLOAD' "$work/old"
    ENGINE_URL=''
    ( . "$work/branch" ) > "$work/missing"
    grep -q '^WARN' "$work/missing"
    XKOP_NO_ENGINE=1
    ( . "$work/branch" ) > "$work/disabled"
    if grep -qE 'WARN|DOWNLOAD' "$work/disabled"; then exit 1; fi
    XKOP_NO_ENGINE=0
    echo "ok engine skip and genuinely missing asset: $FORMAT"
done
