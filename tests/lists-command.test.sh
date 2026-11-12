#!/bin/sh
# The manual update command must report partial community caches truthfully.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed -n '/^cmd_lists_update()/,/^}/p' "$ROOT/xkop/files/usr/bin/xkop" > "$work/command.sh"
. "$work/command.sh"
lists_update() { return 0; }; lists_subnets_update() { return 1; }
lists_geosite_path() { echo /usr/share/xray/geosite.dat; }
lists_present() { return 0; }; lists_subnets_ready() { return 1; }
result=$(cmd_lists_update)
printf '%s' "$result" | jq -e '.ok==false and .result=="partial" and .geosite_present==true and .subnets_ready==false' >/dev/null || exit 1
echo 'ok   geosite alone is not a successful community update'
lists_subnets_ready() { return 0; }
result=$(cmd_lists_update)
printf '%s' "$result" | jq -e '.ok==true and .result=="present"' >/dev/null || exit 1
echo 'ok   a complete cache is reported as ready'
