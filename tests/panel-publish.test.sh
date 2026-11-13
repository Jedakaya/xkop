#!/bin/sh
# shellcheck shell=ash
# Branch installation uses checked same-filesystem renames, never partial copies.
set -eu
ROOT=${ROOT:-$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)}
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT INT TERM
. "$ROOT/xkop/files/usr/lib/xkop/panel.sh"
command -v panel_publish_bundle >/dev/null || { echo 'FAIL checked panel publication unavailable'; exit 1; }
mkdir "$t/live" "$t/stage"
cp -R "$ROOT/client-panel/." "$t/live/"
cp -R "$ROOT/client-panel/." "$t/stage/"
chmod 755 "$t/live/cgi-bin/"* "$t/stage/cgi-bin/"*
echo 'old-release' >> "$t/live/index.html"
echo 'new-release' >> "$t/stage/index.html"
command mv "$t/stage/cgi-bin/auth" "$t/auth"
if panel_publish_bundle "$t/stage" "$t/live"; then echo 'FAIL incomplete candidate published'; exit 1; fi
tail -n 1 "$t/live/index.html" | grep -qx old-release
command mv "$t/auth" "$t/stage/cgi-bin/auth"
mv() {
    if [ "$1" = "$t/stage" ]; then return 1; fi
    command mv "$@"
}
if panel_publish_bundle "$t/stage" "$t/live"; then echo 'FAIL rename error hidden'; exit 1; fi
tail -n 1 "$t/live/index.html" | grep -qx old-release
[ -s "$t/stage/cgi-bin/auth" ]
echo 'ok failed bundle rename restores complete old bundle and preserves candidate'
mv() {
    case "$1" in "$t/stage" | "$t/live".previous.*/bundle) return 1 ;; esac
    command mv "$@"
}
if panel_publish_bundle "$t/stage" "$t/live"; then echo 'FAIL failed restore hidden'; exit 1; fi
[ ! -d "$t/live" ]
found=0
for backup in "$t/live".previous.*/bundle; do
    [ -s "$backup/index.html" ] || continue
    tail -n 1 "$backup/index.html" | grep -qx old-release
    command mv "$backup" "$t/live"
    found=1
done
[ "$found" -eq 1 ]
unset -f mv
echo 'ok failed restore preserves rollback directory and never mixes assets'
panel_publish_bundle "$t/stage" "$t/live"
tail -n 1 "$t/live/index.html" | grep -qx new-release
[ ! -d "$t/stage" ]
echo 'ok complete bundle published by rename'
