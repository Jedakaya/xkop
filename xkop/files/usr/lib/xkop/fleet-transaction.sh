#!/bin/sh
# shellcheck shell=ash
# Owner-enabled transaction, with independent durable recovery.
# shellcheck disable=SC2154
set -eu
umask 077
export LC_ALL=C
STATE=/etc/xkop/fleet
TX="$STATE/transaction"
WORK=
TEMP_TX=
fail() { echo "fleet-transaction: $1" >&2; exit 1; }
cleanup() {
    [ -z "$WORK" ] || rm -rf "$WORK"
    [ -z "$TEMP_TX" ] || rm -rf "$TEMP_TX"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
[ "$#" -eq 2 ] || fail 'usage: start|recover MANIFEST_SHA256'
action=$1
pin=$2
case "$pin" in *[!a-f0-9]*) fail 'invalid manifest hash';; esac
[ "${#pin}" -eq 64 ] || fail 'invalid manifest hash'
[ -d "$STATE" ] && [ ! -L "$STATE" ] && [ ! -L /etc/xkop ] || fail 'invalid state directory'
exec 9> "$STATE/transaction.lock"
# Children inherit this descriptor. A surviving installer keeps the lock even
# when its caller dies, so another recovery cannot overlap it.
flock -n 9 || fail 'transaction busy'
WORK=$(mktemp -d)

journal() {
    jq -nc --arg state "$1" --arg pin "$pin" --argjson at "$(date +%s)" \
        '{schema:1,state:$state,manifest_sha256:$pin,updated_at:$at}' > "$TX/journal.json.new"
    mv "$TX/journal.json.new" "$TX/journal.json"
    sync
}

load_libs() {
    # shellcheck source=/dev/null
    . "$TX/lib/fleet-update.sh"
    # shellcheck source=/dev/null
    . "$TX/lib/fleet-native.sh"
    manifest="$TX/bundle/manifest.json"
    export XKOP_FLEET_HEALTH_CONFIG="$TX/health.json"
    fu_format=$(jq -r .format "$manifest")
}

verify_recovery() {
    (cd "$TX" && sha256sum -c recovery.sha256 >/dev/null) || return 1
    [ "$(fleet_update_hash "$manifest")" = "$pin" ] || return 1
    usign -V -q -p "$TX/release.pub" -m "$manifest" -x "$manifest.sig" || return 1
    # Expiration prevents starting an update; never prevent already armed rollback.
    local issued
    issued=$(jq -r .issued "$manifest")
    jq -e --argjson now "$issued" -f "$TX/lib/fleet-manifest.jq" "$manifest" >/dev/null || return 1
    fleet_update_artifacts "$manifest" "$TX/bundle" '' no
    fleet_native_validate "$manifest" "$TX/bundle"
}

package_command() {
    local direction="$1" simulation="$2" file name version hash
    shift 2
    set --
    jq -r --arg direction "$direction" '.packages[] | .[$direction].file' "$manifest" > "$WORK/files"
    while IFS= read -r file; do set -- "$@" "$TX/bundle/$file"; done < "$WORK/files"
    if [ "$fu_format" = apk ]; then
        if [ "$simulation" = yes ]; then
            apk --no-network --allow-untrusted --simulate add "$@"
        else
            apk --no-network --allow-untrusted add "$@" || return 1
            if [ "$direction" = rollback ]; then
                # add may no-op when the database still names the old version,
                # despite partially replaced files. Reinstall exact cached bytes.
                mkdir -p "$TX/cache"
                for file do
                    apk adbdump --format json "$file" > "$WORK/cache-meta" || return 1
                    name=$(jq -r .info.name "$WORK/cache-meta")
                    version=$(jq -r .info.version "$WORK/cache-meta")
                    hash=$(jq -r .info.hashes "$WORK/cache-meta" | cut -c 1-8)
                    case "$hash" in *[!a-f0-9]*) return 1;; esac
                    [ "${#hash}" -eq 8 ] || return 1
                    cp "$file" "$TX/cache/$name-$version.$hash.apk" || return 1
                done
                set --
                jq -r '.packages[].name' "$manifest" > "$WORK/names"
                while IFS= read -r name; do set -- "$@" "$name"; done < "$WORK/names"
                apk --no-network --allow-untrusted --cache-dir "$TX/cache" fix --reinstall "$@" || return 1
            fi
        fi
    else
        # Empty private feeds/list directory: dependencies must already exist.
        if [ "$simulation" = yes ]; then
            opkg -f "$TX/opkg.conf" -l "$TX/empty-lists" --noaction --force-downgrade install "$@"
        else
            opkg -f "$TX/opkg.conf" -l "$TX/empty-lists" --force-downgrade --force-reinstall install "$@"
        fi
    fi
}

check_plan() {
    local direction="$1" operation name
    package_command "$direction" yes > "$WORK/plan" 2>&1 || return 1
    # Only allow operations concerning the signed set. No dependency upgrades,
    # removals, or installs outside it, even when a repository is cached locally.
    awk '
      /^\([0-9]+\/[0-9]+\) / {print $2, $3; next}
      /^(Installing|Upgrading|Downgrading|Reinstalling|Removing|Purging) / {print $1, $2}
    ' "$WORK/plan" > "$WORK/changes"
    while read -r operation name; do
        case "$operation" in Installing|Upgrading|Downgrading|Reinstalling) ;; *) return 1;; esac
        jq -e --arg name "$name" '.packages | any(.[]; .name == $name)' "$manifest" >/dev/null || return 1
    done < "$WORK/changes"
    if [ "$direction" = forward ]; then
        jq -r '.packages[].name' "$manifest" > "$WORK/planned-names"
        while IFS= read -r name; do
            awk -v name="$name" '$2 == name {found=1} END {exit !found}' "$WORK/changes" || return 1
        done < "$WORK/planned-names"
    fi
}

versions_match() {
    local direction="$1" name expected
    fleet_update_platform
    jq -r --arg direction "$direction" '.packages[] | [.name, .[$direction]] | @tsv' "$manifest" > "$WORK/expected"
    while IFS="$(printf '\t')" read -r name expected; do
        [ "$(fleet_update_installed "$name")" = "$expected" ] || return 1
    done < "$WORK/expected"
}

restore_config() {
    local entry
    [ -d /etc/xkop ] && [ ! -L /etc/xkop ] && [ ! -L /etc/config ] || return 1
    # Exact snapshot restoration: remove files added by a failed migration too.
    for entry in /etc/xkop/* /etc/xkop/.[!.]* /etc/xkop/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        [ "$entry" = /etc/xkop/fleet ] && continue
        rm -rf "$entry" || return 1
    done
    rm -f /etc/config/xkop /etc/config/dhcp
    tar -xf "$TX/config.tar" -C / || return 1
    tar -xf "$TX/state.tar" -C /etc/xkop || return 1
}

rollback() {
    journal rolling_back
    if ! (verify_recovery); then journal recovery_failed; return 1; fi
    if ! package_command rollback no >> "$TX/operations.log" 2>&1; then
        journal recovery_failed; return 1
    fi
    if ! restore_config || ! versions_match from || ! sh "$TX/check-health" rollback; then
        journal recovery_failed; return 1
    fi
    journal rolled_back
}

case "$action" in start|recover) ;; *) fail 'invalid action';; esac
if [ -e "$TX" ]; then
    [ -d "$TX" ] && [ ! -L "$TX" ] || fail 'invalid transaction directory'
    jq -e --arg pin "$pin" '.schema == 1 and .manifest_sha256 == $pin' "$TX/journal.json" >/dev/null \
        || fail 'another transaction owns recovery state'
    state=$(jq -r .state "$TX/journal.json")
    case "$state" in
        committed|rolled_back) printf 'transaction: %s\n' "$state"; exit 0;;
        armed|installing|verifying|rolling_back|recovery_failed) ;;
        *) fail 'unknown transaction state';;
    esac
    [ "$action" = recover ] || fail 'interrupted transaction requires recovery'
    # Never source a saved library before checking its stored integrity record.
    if ! (cd "$TX" && sha256sum -c recovery.sha256 >/dev/null); then
        journal recovery_failed
        fail 'recovery implementation or snapshot is damaged'
    fi
    load_libs
    rollback
    exit $?
fi
[ "$action" = start ] || fail 'no transaction to recover'
[ -f "$STATE/enabled" ] || fail 'management is not enabled'
[ -f "$STATE/allow-install" ] || fail 'installation is not enabled by owner'
source_lib=$(cd "$(dirname "$0")" && pwd)
TEMP_TX=$(mktemp -d "$STATE/.transaction.XXXXXX")
TX="$TEMP_TX"
mkdir "$TX/lib" "$TX/empty-lists"
cp "$source_lib/fleet-update.sh" "$source_lib/fleet-native.sh" "$source_lib/fleet-manifest.jq" "$TX/lib/"
cp "$0" "$TX/runner.sh"
cp "$source_lib/fleet-health.sh" "$TX/check-health"
cp "$STATE/health.json" "$TX/health.json"
export XKOP_FLEET_HEALTH_CONFIG="$TX/health.json"
cp "$STATE/release.pub" "$TX/release.pub"
cp -R "$STATE/updates/$pin" "$TX/bundle"
load_libs
export XKOP_FLEET_UPDATE_LIB="$TX/lib/fleet-update.sh"
fleet_update_platform
fleet_update_validate_manifest "$manifest" "$pin"
fleet_update_artifacts "$manifest" "$TX/bundle" '' no
fleet_native_validate "$manifest" "$TX/bundle"
fleet_update_space "$manifest" "$TX" false
printf 'dest root /\narch all 100\narch %s 200\n' "$fu_arch" > "$TX/opkg.conf"
if ! check_plan forward || ! check_plan rollback; then
    fail 'offline dependency or package-plan check failed'
fi
[ -f /etc/config/xkop ] && [ ! -L /etc/config/xkop ] || fail 'configuration snapshot unavailable'
set -- etc/config/xkop
if [ -e /etc/config/dhcp ]; then
    [ -f /etc/config/dhcp ] && [ ! -L /etc/config/dhcp ] || fail 'invalid DNS config'
    set -- "$@" etc/config/dhcp
fi
tar -cf "$TX/config.tar" -C / "$@"
printf './fleet\n' > "$WORK/exclude"
tar -cf "$TX/state.tar" -X "$WORK/exclude" -C /etc/xkop .
# At this point all duplicate artifacts and config snapshots are on disk.
# Budget extra rollback cache plus largest installed set and 8 MiB headroom.
needed=$(jq '([.packages[].rollback.size]|add) +
    ([([.packages[].forward.installed_size]|add), ([.packages[].rollback.installed_size]|add)]|max) + 8388608' "$manifest")
free_kb=$(df -Pk "$TX" | awk 'NR==2 {print $4}')
case "$free_kb" in ''|*[!0-9]*) fail 'unknown remaining storage';; esac
[ "$free_kb" -ge "$(((needed + 1023) / 1024))" ] || fail 'insufficient storage after recovery snapshot'
(cd "$TX" && sha256sum runner.sh check-health release.pub lib/* config.tar state.tar health.json > recovery.sha256)
sh "$TX/check-health" baseline || fail 'baseline health check failed'
[ -f "$STATE/enabled" ] && [ -f "$STATE/allow-install" ] || fail 'management disabled before installation'
journal armed
mv "$TX" "$STATE/transaction"
TX="$STATE/transaction"
TEMP_TX=
sync
load_libs
journal installing
if ! package_command forward no >> "$TX/operations.log" 2>&1; then
    rollback || :
    exit 1
fi
journal verifying
if versions_match to && sh "$TX/check-health" forward; then
    journal committed
else
    rollback || :
    exit 1
fi
