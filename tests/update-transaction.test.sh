#!/bin/sh
# shellcheck disable=SC2034
# Real updater control flow; package managers/network are isolated fault boundaries.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
lab=$(mktemp -d)
trap 'rm -rf "$lab"' EXIT
sed "s|/usr/bin/xray|$lab/xray|g; s|/etc/config/xkop|$lab/config|g; s|/etc/init.d/xkop|$lab/service|g" \
    "$ROOT/xkop/files/usr/lib/xkop/update.sh" > "$lab/update.sh"
. "$lab/update.sh"
. "$ROOT/xkop/files/usr/lib/xkop/lock.sh"
XKOP_RUN_DIR="$lab/run"; XKOP_ROLLBACK_DIR="$lab/rollback"; XKOP_CONFIG=xkop
mkdir -p "$XKOP_RUN_DIR"
printf '#!/bin/sh\nexit 0\n' > "$lab/service"; chmod +x "$lab/service"
printf config > "$lab/config"
log_info() { :; }; log_warn() { :; }; log_error() { :; }
failed=0
check() { if [ "$2" = "$3" ]; then echo "ok $1"; else echo "FAIL $1: expected $2 got $3"; failed=$((failed + 1)); fi; }
apk() { printf '(1/2) Upgrading xkop (0.2.24-r1 -> 0.2.25-r1)\n(2/2) Upgrading unrelated (1-r1 -> 2-r1)\n'; }
update_would_fit "$lab/xkop.apk"; rc=$?
check 'unprepared dependency upgrade rejected' 1 "$rc"
apk() { printf '(1/1) Upgrading xkop (0.2.24-r1 -> 0.2.25-r1)\n'; }
update_would_fit "$lab/xkop.apk"; rc=$?
check 'prepared package alone accepted' 0 "$rc"
unset -f apk
update_installed_version() { printf 0.2.24; }
update_package_version() { case "$1" in xray-xkop) printf 26.9.9-r2;; *) printf 0.2.24-r1;; esac; }
update_pkg_format() { printf '%s' "$FORMAT"; }
update_router_arch() { printf x86_64; }
update_validate_package() { [ -s "$1" ]; }
curl() {
    out='' url=''
    while [ "$#" -gt 0 ]; do case "$1" in -o) out=$2; shift 2;; https://*) url=$1; shift;; *) shift;; esac; done
    case "$url" in */releases/tags/*) cp "$lab/old.json" "$out";;
        *) [ "${FAIL_DOWNLOAD:-0}" = 0 ] || return 22
           jq -e --arg url "$url" '.assets[] | select(.browser_download_url == $url)' "$lab/old.json" >/dev/null || return 22
           printf package > "$out";; esac
}
for FORMAT in apk ipk; do
    suffix=; [ "$FORMAT" = apk ] || suffix=-all
    jq -nc --arg f "$FORMAT" --arg s "$suffix" '{assets: (["xkop-0.2.24-r1", "luci-app-xkop-0.2.24-r1"] | map(. + $s + "." + $f) | . + [("xray-xkop-26.9.9-r2-x86_64." + $f)] | map({name: ., browser_download_url:("https://example.invalid/" + .)}))}' > "$lab/old.json"
    update_stage_rollback xkop luci-app-xkop xray-xkop; rc=$?
    check "$FORMAT exact old assets" 0 "$rc"
    check "$FORMAT engine rollback staged" yes "$([ -s "$XKOP_ROLLBACK_DIR/xray-xkop.$FORMAT" ] && echo yes || echo no)"
    FAIL_DOWNLOAD=1
    update_stage_rollback xkop; rc=$?
    check "$FORMAT rollback download fails closed" 1 "$rc"
    FAIL_DOWNLOAD=0
done
printf good > "$lab/stash"; printf broken > "$lab/xray"; XKOP_ENGINE_STASH="$lab/stash"
update_engine_room_restore 0
check 'partial engine overwritten' good "$(cat "$lab/xray")"
printf good > "$lab/stash"; XKOP_ENGINE_STASH="$lab/stash"
cp() { return 1; }
update_engine_room_restore 0; rc=$?
check 'restore copy failure reported' 1 "$rc"
check 'restore copy failure keeps stash' yes "$([ -s "$lab/stash" ] && echo yes || echo no)"
unset -f cp
# Exercise complete rollback: one successful package cannot hide another failure.
FORMAT=apk
mkdir -p "$XKOP_ROLLBACK_DIR"
printf '0.2.24' > "$XKOP_ROLLBACK_DIR/version"
printf 'xray-xkop 26.9.9-r2\nxkop 0.2.24-r1\nluci-app-xkop 0.2.24-r1\n' > "$XKOP_ROLLBACK_DIR/packages"
update_restore_file() { printf '%s\n' "$2" >> "$lab/restored"; [ "$2" != "${FAIL_PACKAGE:-}" ]; }
engine_wait() { return 0; }
FAIL_PACKAGE=xray-xkop
# Uses the sourced implementation; the later definition injects a different failure.
# shellcheck disable=SC2218
update_rollback; rc=$?
check 'one failed restore fails whole rollback' 1 "$rc"
check 'engine included in rollback' yes "$(grep -qx xray-xkop "$lab/restored" && echo yes || echo no)"
FAIL_PACKAGE=
# shellcheck disable=SC2218
update_rollback; rc=$?
check 'all exact versions and health restored' 0 "$rc"
update_prepare_ram() { :; }; update_reclaim_flash() { :; }; update_latest_json() { :; }
update_latest_version() { printf 0.2.25; }
update_asset_url() { printf 'https://example.invalid/%s%s' "$1" "$2"; }
update_engine_installed_version() { printf 26.9.9-r2; }
curl() { while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then printf package > "$2"; return 0; fi; shift; done; }
update_install_file() { echo installed >> "$lab/mutations"; return 1; }
update_stage_rollback() { return 1; }
lock_acquire update
update_apply > "$lab/result"
check 'simultaneous update refused before download' update_busy "$(jq -r .error "$lab/result")"
lock_release update
update_apply > "$lab/result"
check 'failed preparation prevents installation' no "$([ -f "$lab/mutations" ] && echo yes || echo no)"
check 'preparation result' rollback_unavailable "$(jq -r .error "$lab/result")"
update_stage_rollback() { :; }; update_rollback() { return 1; }; update_engine_make_room() { :; }
update_apply > "$lab/result"
check 'failed rollback reported honestly' false "$(jq -r .rolled_back "$lab/result")"

# Installer shares the same failure boundary, including an unowned old engine.
sed -n '/^engine_room_restore()/,/^}/p' "$ROOT/install.sh" | sed "s|/usr/bin/xray|$lab/xray|g" > "$lab/installer.sh"
. "$lab/installer.sh"
note() { :; }; warn() { :; }
printf good > "$lab/stash"; printf broken > "$lab/xray"; ENGINE_STASH="$lab/stash"
engine_room_restore 0
check 'installer overwrites partial engine' good "$(cat "$lab/xray")"
printf good > "$lab/stash"; ENGINE_STASH="$lab/stash"
cp() { return 1; }
engine_room_restore 0; rc=$?
check 'installer copy failure reported' 1 "$rc"
check 'installer copy failure keeps stash' yes "$([ -s "$lab/stash" ] && echo yes || echo no)"
echo "failures: $failed"
[ "$failed" = 0 ]
