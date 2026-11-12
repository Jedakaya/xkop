#!/bin/sh
# Action failures must survive the status JSON merge.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_STATE_DIR="$work" XKOP_RUN_DIR="$work"
. "$ROOT/xkop/files/usr/lib/xkop/service.sh"
service_init_action() { return 42; }
service_status_json() { printf '{"ok":true,"dns_ready":true,"engine":{"running":false}}'; }
result=$(service_control stop)
printf '%s' "$result" | jq -e '.ok==false and .error=="service_action_failed" and .action_exit_code==42' >/dev/null || exit 1
echo 'ok   stop failure is not overwritten by status.ok'
service_init_action() { return 0; }
service_status_json() { printf '{"ok":true,"dns_ready":false,"engine":{"running":false}}'; }
result=$(service_control stop)
printf '%s' "$result" | jq -e '.ok==false' >/dev/null || exit 1
echo 'ok   unconfirmed DNS restoration prevents stop success'
service_status_json() { printf '{"ok":true,"dns_ready":true,"engine":{"running":false}}'; }
result=$(service_control stop)
printf '%s' "$result" | jq -e '.ok==true and .action_exit_code==0' >/dev/null || exit 1
echo 'ok   successful stop remains successful'
