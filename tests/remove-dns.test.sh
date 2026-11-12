#!/bin/sh
# Execute the packaged removal hook with isolated external commands.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf '#!/bin/sh\nexit "${REMOVE_DNS_RC:-0}"\n' > "$work/xkop"
printf '#!/bin/sh\necho stopped > "$REMOVE_STOP_FILE"\n' > "$work/init"
chmod +x "$work/xkop" "$work/init"
export REMOVE_STOP_FILE="$work/stopped"
sed -n '/^define Package\/xkop\/prerm$/,/^endef$/p' "$ROOT/xkop/Makefile" \
    | sed '1d;$d' | sed "s|/usr/bin/xkop|$work/xkop|g;s|/etc/init.d/xkop|$work/init|g" > "$work/prerm"
REMOVE_DNS_RC=1; export REMOVE_DNS_RC
sh "$work/prerm"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$work/stopped" ] || {
    echo 'FAIL removal continued despite failed DNS restoration'; exit 1;
}
echo 'ok   failed DNS restoration aborts the removal hook'
REMOVE_DNS_RC=0; export REMOVE_DNS_RC
sh "$work/prerm"; rc=$?
[ "$rc" = 0 ] && [ -e "$work/stopped" ] || exit 1
echo 'ok   confirmed DNS restoration permits stopping the service'
