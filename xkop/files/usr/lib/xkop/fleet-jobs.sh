#!/bin/sh
# shellcheck shell=ash
# Device-scoped release preparation only. Never execute server-provided code.
# STATE comes from xkop-fleet; jq variables deliberately remain quoted.
# shellcheck disable=SC2154,SC2153,SC2016

fleet_job_save() {
    jq "$@" "$STATE/jobs/current.json" > "$STATE/jobs/current.new"
    mv "$STATE/jobs/current.new" "$STATE/jobs/current.json"
    sync
}

fleet_job_finish() {
    mv "$STATE/jobs/current.json" "$STATE/jobs/last-result.json"
    sync
}

fleet_job_event() {
    local state="$1" reason="$2"
    fleet_job_save --arg state "$state" --arg reason "$reason" \
        '.phase="report" | .sequence=2 | .state=$state | .code=$reason'
}

fleet_job_poll() {
    jq '{device_id}' "$STATE/identity.json" > "$WORK/payload.json"
    request jobs/poll "$secret"
}

fleet_job_report() {
    local current="$STATE/jobs/current.json" expected_seq expected_job
    jq '{device_id,job_id,sequence,state,code}' "$current" > "$WORK/payload.json"
    expected_seq=$(jq -r .sequence "$current")
    expected_job=$(jq -r .job_id "$current")
    request jobs/result "$secret" || return 1
    jq -e --arg job "$expected_job" --argjson seq "$expected_seq" \
        '.accepted==true and .job_id==$job and .sequence==$seq and
        (.state=="preparing" or .state=="prepared" or .state=="failed" or
         .state=="installing" or .state=="installed" or .state=="rolled_back")' "$WORK/response.json" >/dev/null
}

fleet_job_validate() {
    local file="$1"
    jq -e --arg device "$device_id" '
        def hex($n): type=="string" and length==$n and
          ((explode-("0123456789abcdef"|explode))|length==0);
        .device_id==$device and (.job_id|hex(32)) and (.action=="prepare_update" or .action=="install_update") and
        (.expires|type=="number" and floor==. and .>0 and .<=4102444800) and
        (.release|type=="object") and (.release.manifest_sha256|hex(64)) and
        (.release.manifest_url|type=="string" and length<=2048) and
        (.release.version|type=="string" and length>0 and length<=96) and
        (.release.from_version|type=="string" and length>0 and length<=96) and
        (.release.format=="apk" or .release.format=="ipk") and
        (.release.arch|type=="string") and (.release.openwrt_series|type=="string")
    ' "$file" >/dev/null 2>&1 || return 1
    valid_url "$(jq -r .release.manifest_url "$file")"
}

fleet_job_matches_release() {
    local current="$STATE/jobs/current.json" manifest="$1" target previous
    jq -e --slurpfile job "$current" '
       .format==$job[0].release.format and .arch==$job[0].release.arch and
       .openwrt_series==$job[0].release.openwrt_series' "$manifest" >/dev/null || return 1
    target=$(jq -r '.packages[]|select(.name=="xkop")|.to' "$manifest")
    previous=$(jq -r '.packages[]|select(.name=="xkop")|.from' "$manifest")
    [ "${target%-r*}" = "$(jq -r .release.version "$current")" ] &&
        [ "${previous%-r*}" = "$(jq -r .release.from_version "$current")" ]
}

fleet_jobs_tick() {
    [ -f "$STATE/enabled" ] || return 0
    # Keep native preparation and job delivery mutually exclusive even after
    # SIGKILL: the child inherits fd 8, so another delivery waits for it to exit.
    exec 8> "${XKOP_FLEET_JOB_LOCK:-/tmp/xkop-fleet-jobs.lock}"
    flock -n 8 || return 1
    [ -f "$STATE/enabled" ] || return 0
    WORK=$(mktemp -d)
    load_identity
    mkdir -p "$STATE/jobs"
    local current="$STATE/jobs/current.json" phase job_id pin url reason
    if [ ! -f "$current" ]; then
        fleet_job_poll || return 1
        jq -e '.job==null' "$WORK/response.json" >/dev/null && return 0
        jq '.job' "$WORK/response.json" > "$WORK/job.json"
        fleet_job_validate "$WORK/job.json" || fail 'invalid release job'
        jq '. + {phase:"claim",sequence:1,state:(if .action=="install_update" then "installing" else "preparing" end),code:""}' "$WORK/job.json" > "$STATE/jobs/current.new"
        mv "$STATE/jobs/current.new" "$current"
        sync
    fi
    fleet_job_validate "$current" || fail 'invalid saved job'
    phase=$(jq -r .phase "$current")
    job_id=$(jq -r .job_id "$current")
    pin=$(jq -r .release.manifest_sha256 "$current")
    url=$(jq -r .release.manifest_url "$current")
    local running=preparing
    if [ "$(jq -r .action "$current")" = install_update ]; then
        running=installing
        # shellcheck source=/dev/null
        . "${XKOP_FLEET_INSTALL_LIB:-/usr/lib/xkop/fleet-install.sh}"
    fi
    case "$phase" in
        complete|aborted)
            # Terminal intent is already durable; finish a move interrupted by
            # power loss without repeating downloads or reports.
            fleet_job_finish
            return 0
            ;;
        claim)
            if ! fleet_job_report; then
                if [ "${code:-}" = 400 ]; then
                    # The owner may have cancelled, or the unclaimed job expired.
                    # Only abandon an unstarted claim when server confirms it is
                    # no longer the active job. A running preparation is preserved.
                    fleet_job_poll || return 1
                    if jq -e --arg id "$job_id" '.job==null or .job.job_id!=$id' "$WORK/response.json" >/dev/null; then
                        fleet_job_save '.phase="aborted" | .state="not_accepted"'
                        fleet_job_finish
                        return 0
                    fi
                fi
                return 1
            fi
            if [ "$(jq -r .state "$WORK/response.json")" != "$running" ]; then
                [ "$running" != installing ] || fleet_install_ack || return 1
                fleet_job_save --arg state "$(jq -r .state "$WORK/response.json")" '.phase="complete" | .state=$state'
                fleet_job_finish
                return 0
            fi
            if [ "$running" = installing ]; then
                fleet_job_save '.phase="installing"'
                fleet_install_tick || return 1
                [ "$(jq -r .phase "$current")" = report ] || return 0
            else
            fleet_job_save '.phase="preparing"'
            if [ "$(date +%s)" -ge "$(jq -r .expires "$current")" ]; then
                fleet_job_event failed expired
            else
                reason=
                sh "$0" prepare "$url" "$pin" >/dev/null 2>&1 || reason=prepare_failed
                if [ -z "$reason" ]; then
                    sh "$0" check-update "$pin" >/dev/null 2>&1 || reason=native_check_failed
                fi
                if [ -z "$reason" ]; then
                    fleet_job_matches_release "$STATE/updates/$pin/manifest.json" || reason=mismatched_release
                fi
                if [ -z "$reason" ]; then fleet_job_event prepared ''; else fleet_job_event failed "$reason"; fi
            fi
            fi
            ;;
        installing)
            fleet_install_tick || return 1
            [ "$(jq -r .phase "$current")" = report ] || return 0
            ;;
        preparing)
            # After a crash never start a second download blindly. Validate the
            # local complete set, or report interruption; nothing is installed.
            if sh "$0" check-update "$pin" >/dev/null 2>&1 && fleet_job_matches_release "$STATE/updates/$pin/manifest.json"; then
                fleet_job_event prepared ''
            else
                fleet_job_event failed interrupted
            fi
            ;;
        report) ;;
        *) fail 'unknown saved job phase';;
    esac
    [ -f "$STATE/enabled" ] || return 1
    fleet_job_report || return 1
    [ "$running" != installing ] || fleet_install_ack || return 1
    fleet_job_save '.phase="complete"'
    fleet_job_finish
}
