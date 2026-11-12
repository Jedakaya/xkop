#!/bin/sh
# shellcheck shell=ash
# Read package internals only. Caller authenticates manifest and artifact bytes.

fleet_native_integrity() {
    local file="$1" format="$2"
    if [ "$format" = apk ]; then
        # Owner signature authenticated the outer bytes; native verification
        # checks the complete payload, not just its readable ADB metadata.
        apk --allow-untrusted verify "$file" >/dev/null 2>&1 || return 1
    else
        tar -xzOf "$file" ./data.tar.gz > "$WORK/data.tar.gz" 2>/dev/null || return 1
        # BusyBox gzip need not implement -t. Decompressing to /dev/null validates
        # the complete stream and CRC independently of tar's early end marker.
        gzip -dc "$WORK/data.tar.gz" > /dev/null 2>&1 || return 1
        tar -tzf "$WORK/data.tar.gz" > /dev/null 2>&1 || return 1
    fi
}

fleet_native_metadata() {
    local file="$1" format="$2" output="$3"
    if [ "$format" = apk ]; then
        apk adbdump --format json "$file" > "$WORK/package-adb.json" 2>/dev/null || return 1
        jq -e '.info | {name, version, arch, installed_size: .["installed-size"]}' \
            "$WORK/package-adb.json" > "$output" || return 1
    elif [ "$format" = ipk ]; then
        # Extract exact members to stdout, never unpack paths or execute scripts.
        # Separate commands keep an outer archive failure visible without pipefail.
        tar -xzOf "$file" ./control.tar.gz > "$WORK/control.tar.gz" 2>/dev/null || return 1
        tar -xzOf "$WORK/control.tar.gz" ./control > "$WORK/control" 2>/dev/null || return 1
        jq -Rse '
          split("\n") as $lines |
          def field($key): [$lines[] | select(startswith($key + ": ")) | ltrimstr($key + ": ")]
            | if length == 1 then .[0] else error("missing/duplicate control field") end;
          {name: field("Package"), version: field("Version"), arch: field("Architecture"),
           installed_size: (field("Installed-Size") | tonumber)}
        ' "$WORK/control" > "$output" || return 1
    else
        return 1
    fi
}

fleet_native_validate() {
    local manifest="$1" folder="$2" name version file size format arch
    format=$(jq -r '.format' "$manifest")
    arch=$(jq -r '.arch' "$manifest")
    jq -r '.packages[] | [.name,.to,.forward.file,.forward.installed_size],
        [.name,.from,.rollback.file,.rollback.installed_size] | @tsv' \
        "$manifest" > "$WORK/native.tsv"
    while IFS="$(printf '\t')" read -r name version file size; do
        fleet_native_metadata "$folder/$file" "$format" "$WORK/package-meta.json" \
            || fail 'cannot read package metadata'
        jq -e --arg name "$name" --arg version "$version" --arg arch "$arch" \
            --arg format "$format" --argjson size "$size" '
            .name == $name and .version == $version and .installed_size == $size and
            (.arch == $arch or ($name != "xray-xkop" and
              (($format == "apk" and .arch == "noarch") or ($format == "ipk" and .arch == "all"))))
        ' "$WORK/package-meta.json" >/dev/null 2>&1 || fail 'package metadata does not match signed manifest'
        fleet_native_integrity "$folder/$file" "$format" || fail 'package archive payload is invalid'
    done < "$WORK/native.tsv"
}

fleet_native_check() {
    local pin="$1" folder
    case "$pin" in *[!a-f0-9]*) fail 'invalid approved manifest SHA256';; esac
    [ "${#pin}" -eq 64 ] || fail 'approved manifest SHA256 is required'
    [ -f "$STATE/enabled" ] || fail 'management is not enabled'
    lock
    [ -f "$STATE/enabled" ] || fail 'management was disabled before inspection'
    folder="$STATE/updates/$pin"
    [ -d "$folder" ] && [ ! -L "$STATE/updates" ] && [ ! -L "$folder" ] || fail 'prepared bundle is missing'
    rm -f "$folder/native-checked.json"
    fleet_update_platform
    fleet_update_validate_manifest "$folder/manifest.json" "$pin"
    fleet_update_artifacts "$folder/manifest.json" "$folder" '' no
    fleet_native_validate "$folder/manifest.json" "$folder"
    fleet_update_space "$folder/manifest.json" "$folder" false
    jq -nc --arg hash "$pin" --argjson at "$(date +%s)" \
        '{state:"metadata_checked",installation_allowed:false,manifest_sha256:$hash,checked_at:$at}' \
        > "$folder/native-checked.json.new"
    mv "$folder/native-checked.json.new" "$folder/native-checked.json"
    printf 'xkop-fleet: native package metadata verified; nothing installed\n'
}
