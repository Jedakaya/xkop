#!/bin/sh
# shellcheck shell=ash
# Sourced by xkop-fleet after opt-in checks, under its operation lock.
# This module prepares signed packages ONLY. It never invokes installation.

fleet_update_download() {
    local url="$1" output="$2" limit="$3" code
    code=$(curl -q --silent --fail --proto '=https' --proto-redir '=https' --noproxy '*' \
        --connect-timeout 5 --max-time 120 --max-filesize "$limit" \
        --output "$output" --write-out '%{http_code}' "$url") || return 1
    [ "$code" = 200 ] && [ -f "$output" ] && [ "$(wc -c < "$output")" -le "$limit" ]
}

fleet_update_hash() { sha256sum "$1" | cut -d ' ' -f 1; }

fleet_update_platform() {
    local release_file="${XKOP_FLEET_RELEASE_FILE:-/etc/openwrt_release}"
    [ -r "$release_file" ] || fail 'cannot identify OpenWrt'
    # Read literal fields, never source shell code from an input document.
    fu_arch=$(sed -n "s/^DISTRIB_ARCH='\([^']*\)'$/\1/p" "$release_file")
    fu_release=$(sed -n "s/^DISTRIB_RELEASE='\([^']*\)'$/\1/p" "$release_file")
    fu_series=$(printf '%s' "$fu_release" | cut -d . -f 1,2)
    [ -n "$fu_arch" ] && [ -n "$fu_series" ] || fail 'unknown OpenWrt platform'
    if command -v apk >/dev/null 2>&1; then
        fu_format=apk
        apk list --installed > "$WORK/inventory" 2>/dev/null || fail 'package inventory unavailable'
    elif command -v opkg >/dev/null 2>&1; then
        fu_format=ipk
        opkg list-installed > "$WORK/inventory" 2>/dev/null || fail 'package inventory unavailable'
    else
        fail 'supported package manager is unavailable'
    fi
}

fleet_update_installed() {
    # Names are an explicit enum validated before this function is called.
    if [ "$fu_format" = apk ]; then
        sed -n "s/^$1-\([^ ]*\) .*/\1/p" "$WORK/inventory"
    else
        awk -v name="$1" '$1 == name && $2 == "-" {print $3}' "$WORK/inventory"
    fi
}

fleet_update_validate_manifest() {
    local manifest="$1" pin="$2" now schema
    [ "$(fleet_update_hash "$manifest")" = "$pin" ] || fail 'manifest does not match approved SHA256'
    usign -V -q -p "$STATE/release.pub" -m "$manifest" -x "$manifest.sig" 2>/dev/null \
        || fail 'manifest signature is invalid'
    now=$(date +%s)
    [ "$now" -ge 1735689600 ] || fail 'router clock is not ready'
    schema="${XKOP_FLEET_UPDATE_LIB:-/usr/lib/xkop/fleet-update.sh}"
    schema="${schema%/*}/fleet-manifest.jq"
    jq -e --argjson now "$now" -f "$schema" "$manifest" >/dev/null 2>&1 \
        || fail 'invalid or expired release manifest'
    jq -e --arg arch "$fu_arch" --arg format "$fu_format" --arg series "$fu_series" \
        '.arch == $arch and .format == $format and .openwrt_series == $series' "$manifest" >/dev/null \
        || fail 'release is incompatible with this OpenWrt'
    jq -r '.packages[] | [.name, .from] | @tsv' "$manifest" > "$WORK/versions.tsv"
    local name previous installed
    while IFS="$(printf '\t')" read -r name previous; do
        installed=$(fleet_update_installed "$name")
        [ -n "$installed" ] && [ "$installed" = "$previous" ] \
            || fail 'installed version does not match the rollback package'
    done < "$WORK/versions.tsv"
    if [ -n "$(fleet_update_installed luci-app-xkop)" ]; then
        jq -e '.packages | any(.[]; .name == "luci-app-xkop")' "$manifest" >/dev/null \
            || fail 'installed LuCI requires a matching update and rollback'
    fi
}

fleet_update_space() {
    local manifest="$1" folder="$2" include_downloads="$3" bytes free_kb
    bytes=$(jq --argjson download "$include_downloads" '
        ([.packages[].forward.installed_size] | add) + 8388608 +
        (if $download then ([.packages[] | .forward.size, .rollback.size] | add) else 0 end)' "$manifest")
    free_kb=$(df -Pk "$folder" | awk 'NR == 2 {print $4}')
    case "$free_kb" in ''|*[!0-9]*) fail 'free persistent storage is unknown';; esac
    [ "$free_kb" -ge "$(((bytes + 1023) / 1024))" ] || fail 'insufficient persistent storage for update and rollback'
}

fleet_update_artifacts() {
    local manifest="$1" folder="$2" base="$3" download="$4" file hash size actual
    jq -r '.packages[] | .forward, .rollback | [.file, .sha256, .size] | @tsv' \
        "$manifest" > "$WORK/artifacts.tsv"
    while IFS="$(printf '\t')" read -r file hash size; do
        if [ "$download" = yes ]; then
            fleet_update_download "$base/$file" "$folder/$file" "$size" || fail 'package download failed'
        fi
        [ -f "$folder/$file" ] && [ ! -L "$folder/$file" ] || fail 'prepared package is missing'
        [ "$(wc -c < "$folder/$file")" -eq "$size" ] || fail 'package size does not match signed manifest'
        actual=$(fleet_update_hash "$folder/$file")
        [ "$actual" = "$hash" ] || fail 'package hash does not match signed manifest'
    done < "$WORK/artifacts.tsv"
}

fleet_update_prepare() {
    local url="$1" pin="$2" base final manifest staging
    [ -f "$STATE/enabled" ] || fail 'management is not enabled'
    [ -f "$STATE/release.pub" ] || fail 'owner must provision a release verification key first'
    command -v usign >/dev/null 2>&1 || fail 'usign is required; nothing was installed'
    valid_url "$url" || fail 'an HTTPS release URL is required'
    case "$pin" in *[!a-f0-9]*) fail 'invalid approved manifest SHA256';; esac
    [ "${#pin}" -eq 64 ] || fail 'approved manifest SHA256 is required'
    case "$url" in */*.json) ;; *) fail 'manifest URL must end in a JSON filename';; esac
    base=${url%/*}
    lock
    [ -f "$STATE/enabled" ] || fail 'management was disabled before preparation'
    fleet_update_platform
    # Small manifest is verified before using filenames or downloading packages.
    manifest="$WORK/manifest.json"
    fleet_update_download "$url" "$manifest" 16384 || fail 'manifest download failed'
    fleet_update_download "$url.sig" "$manifest.sig" 1024 || fail 'signature download failed'
    fleet_update_validate_manifest "$manifest" "$pin"
    [ ! -L "$STATE/updates" ] || fail 'invalid update storage'
    mkdir -p "$STATE/updates"
    chmod 700 "$STATE/updates"
    final="$STATE/updates/$pin"
    if [ -e "$final" ]; then
        [ -d "$final" ] && [ ! -L "$final" ] || fail 'invalid existing prepared directory'
        rm -f "$final/prepared.json"
        [ -f "$final/manifest.json" ] && [ ! -L "$final/manifest.json" ] || fail 'prepared manifest is missing'
        fleet_update_validate_manifest "$final/manifest.json" "$pin"
        fleet_update_artifacts "$manifest" "$final" "$base" no
        fleet_update_space "$manifest" "$final" false
        staging="$final"
    else
        fleet_update_space "$manifest" "$STATE/updates" true
        staging=$(mktemp -d "$STATE/updates/.prepare.XXXXXX")
        # Keep partial downloads under the EXIT cleanup even on failure/SIGTERM.
        cp "$WORK/manifest.json" "$WORK/manifest.json.sig" "$WORK/inventory" "$staging/"
        rm -rf "$WORK"
        WORK="$staging"
        manifest="$staging/manifest.json"
        fleet_update_artifacts "$manifest" "$staging" "$base" yes
        fleet_update_space "$manifest" "$staging" false
    fi
    [ -f "$STATE/enabled" ] || fail 'management was disabled during preparation'
    jq -nc --arg hash "$pin" --argjson at "$(date +%s)" \
        '{state:"prepared",installation_allowed:false,manifest_sha256:$hash,prepared_at:$at}' > "$staging/prepared.json.new"
    mv "$staging/prepared.json.new" "$staging/prepared.json"
    if [ "$staging" != "$final" ]; then
        # Same filesystem: a partial package set never becomes the final receipt.
        mv "$staging" "$final"
        WORK=""
    fi
    printf 'xkop-fleet: signed update and rollback packages prepared; nothing installed\n'
}
