#!/bin/sh
# shellcheck shell=ash
# Independent owner-enabled supervisor. Runs from durable state across package replacement.
set -eu
umask 077
export LC_ALL=C
STATE=/etc/xkop/fleet
SUP="$STATE/supervisor"
TX="$STATE/transaction"
SELF=$(readlink -f "$0")
fail() { echo "fleet-guardian: $1" >&2; exit 1; }

[ -d "$STATE" ] && [ ! -L "$STATE" ] && [ ! -L /etc/xkop ] || fail 'invalid state'
mkdir -p "$SUP"
[ ! -L "$SUP" ] || fail 'invalid supervisor directory'
boot=$(cat /proc/sys/kernel/random/boot_id)
uptime_seconds() { cut -d . -f 1 /proc/uptime; }
pin_valid() { case "$1" in *[!a-f0-9]*) return 1;; esac; [ "${#1}" -eq 64 ]; }
duration_valid() { case "$1" in ''|*[!0-9]*) return 1;; esac; [ "$1" -ge 3 ] && [ "$1" -le 900 ]; }
job_valid() { case "$1" in *[!a-f0-9]*) return 1;; esac; [ "${#1}" -eq 32 ]; }
retire_previous() {
    [ ! -f "$SUP/session.json" ] || fail 'worker still active'
    [ -f "$SUP/active.json" ] || { [ ! -e "$TX" ] || fail 'orphaned transaction'; return; }
    previous=$(jq -r .job_id "$SUP/active.json")
    [ "$(cat "$SUP/acknowledged" 2>/dev/null)" = "$previous" ] || fail 'result not acknowledged'
    if [ -e "$TX" ]; then
        [ -d "$TX" ] && [ ! -L "$TX" ] || fail 'unsafe transaction'
        case "$(jq -r .state "$TX/journal.json")" in committed|rolled_back) ;; *) fail 'unresolved recovery';; esac
        [ ! -L "$STATE/last-transaction" ] || fail 'unsafe archive'
        rm -rf "$STATE/last-transaction"
        mv "$TX" "$STATE/last-transaction"
    fi
    rm -f "$SUP/active.json" "$SUP/acknowledged" "$SUP/recovery-attempt" "$SUP/status.json"
    sync
}
status() {
    [ "$(jq -r .state "$SUP/status.json" 2>/dev/null)" != "$1" ] || return 0
    jq -nc --arg state "$1" --argjson at "$(date +%s)" '{state:$state,updated_at:$at}' > "$SUP/status.json.new"
    mv "$SUP/status.json.new" "$SUP/status.json"
    sync
}
identity() {
    # Strip the comm field (it can contain spaces/parentheses) before indexing.
    [ -r "/proc/$1/stat" ] || return 1
    sed 's/.*) //' "/proc/$1/stat" | awk '{print $4, $20}'
}
session_owned() {
    local actual
    actual=$(identity "$pid") || return 1
    [ "$actual" = "$pid $ticks" ]
}
discard_finished_session() (
    # A crashed cleanup can leave a record after the anchor died. Never signal
    # its numeric PID. Require both no live session members and no installer.
    exec 9> "$STATE/transaction.lock"
    flock -n 9 || exit 1
    for proc_stat in /proc/[0-9]*/stat; do
        info=$(sed 's/.*) //' "$proc_stat" 2>/dev/null | awk '{print $1, $4}')
        case "$info" in "Z $pid") ;; *" $pid") exit 1;; esac
    done
    rm -f "$SUP/session.json" "$SUP/done"
)
lost_session() {
    discard_finished_session || { status session_identity_lost; return 1; }
}
terminate_session() {
    session_owned || return 1
    # Anchor remains alive until KILL, keeping the process-group ID reserved.
    kill -TERM "-$pid" 2>/dev/null || :
    sleep 1
    session_owned || return 1
    kill -KILL "-$pid" 2>/dev/null || return 1
    wait "$pid" 2>/dev/null || :
}
read_session() {
    jq -e '(.pid|type=="number" and .>=2 and floor==.) and
        (.ticks|type=="string" and length>0 and (explode|all(.>=48 and .<=57))) and
        (.deadline|type=="number" and .>=0 and floor==.) and
        (.mode=="start" or .mode=="recover") and (.boot|type=="string")' "$SUP/session.json" >/dev/null || return 1
    pid=$(jq -r .pid "$SUP/session.json")
    ticks=$(jq -r .ticks "$SUP/session.json")
    deadline=$(jq -r .deadline "$SUP/session.json")
    mode=$(jq -r .mode "$SUP/session.json")
}
monitor() {
    read_session || { status invalid_session; return 1; }
    if [ "$(jq -r .boot "$SUP/session.json")" != "$boot" ]; then
        rm -f "$SUP/session.json" "$SUP/done"
        return 0
    fi
    session_owned || { lost_session; return $?; }
    while [ ! -f "$SUP/done" ] && [ "$(uptime_seconds)" -lt "$deadline" ]; do
        sleep 1
        session_owned || { lost_session; return $?; }
    done
    terminate_session || { status session_cleanup_failed; return 1; }
    rm -f "$SUP/session.json" "$SUP/done"
}
launch() {
    local action="$1" pin="$2" limit="$3" n
    rm -f "$SUP/done"
    # Descriptor 7 is the supervisor lock, never inherited by the anchor.
    setsid sh "$SELF" _anchor "$action" "$pin" "$limit" 7>&- >> "$SUP/worker.log" 2>&1 &
    for n in 1 2 3 4 5; do
        : "$n"
        [ ! -f "$SUP/session.json" ] || { monitor; return $?; }
        sleep 1
    done
    status session_launch_failed
    return 1
}
run_once() {
    local state pin limit=120
    [ ! -f "$SUP/session.json" ] || monitor || return 1
    if [ -f "$TX/journal.json" ]; then
        pin=$(jq -er .manifest_sha256 "$TX/journal.json") || return 1
        pin_valid "$pin" || return 1
        state=$(jq -r .state "$TX/journal.json")
        case "$state" in
            committed|rolled_back) status "$state"; return 0;;
            recovery_failed)
                status recovery_failed; return 1;;
            armed|installing|verifying|rolling_back) ;;
            *) status invalid_journal; return 1;;
        esac
        [ ! -f "$SUP/recovery-attempt" ] || { status recovery_interrupted; return 1; }
        # No waiting indefinitely on an installer outside our verified session.
        (exec 9> "$STATE/transaction.lock"; flock -n 9) || { status transaction_busy; return 1; }
        if [ -f "$SUP/active.json" ]; then limit=$(jq -r .recovery_timeout "$SUP/active.json"); fi
        duration_valid "$limit" || return 1
        if ! (cd "$TX" && sha256sum -c recovery.sha256 >/dev/null 2>&1); then
            status recovery_integrity_failed
            return 1
        fi
        printf '%s\n' "$pin" > "$SUP/recovery-attempt"
        sync
        launch recover "$pin" "$limit" || return 1
        state=$(jq -r .state "$TX/journal.json")
        case "$state" in committed|rolled_back) status "$state";; *) status recovery_failed; return 1;; esac
        return 0
    fi
    [ ! -f "$SUP/active.json" ] || { status start_interrupted_before_arm; return 1; }
    [ -f "$SUP/queue.json" ] || return 0
    mv "$SUP/queue.json" "$SUP/active.json"
    sync
    pin=$(jq -r .pin "$SUP/active.json")
    limit=$(jq -r .timeout "$SUP/active.json")
    pin_valid "$pin" && duration_valid "$limit" || return 1
    launch start "$pin" "$limit" || return 1
    # Process completion is not success: inspect the durable transaction result.
    run_once
}

case "${1:-}" in
    _anchor)
        [ "$#" -eq 4 ] || fail 'invalid anchor request'
        mode=$2; pin=$3; limit=$4
        if ! pin_valid "$pin" || ! duration_valid "$limit"; then fail 'invalid anchor parameters'; fi
        case "$mode" in start|recover) ;; *) fail 'invalid mode';; esac
        actual=$(identity $$)
        [ "${actual%% *}" = "$$" ] || fail 'worker is not a session leader'
        ticks=${actual#* }
        deadline=$(($(uptime_seconds) + limit))
        # Ignore TERM only in the anchor; executed child scripts reset this trap.
        trap ':' TERM INT HUP
        jq -nc --arg boot "$boot" --argjson pid $$ --arg ticks "$ticks" \
            --arg mode "$mode" --argjson deadline "$deadline" \
            '{boot:$boot,pid:$pid,ticks:$ticks,mode:$mode,deadline:$deadline}' > "$SUP/session.json.new"
        mv "$SUP/session.json.new" "$SUP/session.json"
        sync
        runner="$SUP/runtime/lib/fleet-transaction.sh"
        [ "$mode" = start ] || runner="$TX/runner.sh"
        # Tests may use a source checkout; installed supervisor always uses its copy.
        [ -f "$runner" ] || runner="$(dirname "$SELF")/fleet-transaction.sh"
        rc=0
        sh "$runner" "$mode" "$pin" || rc=$?
        printf '%s\n' "$rc" > "$SUP/done.new"
        mv "$SUP/done.new" "$SUP/done"
        while :; do sleep 60 & wait $! || :; done
        ;;
    serve)
        exec 8> "$SUP/service.lock"
        flock -n 8 || fail 'daemon already running'
        next_report=0
        while :; do
            sh "$SELF" run 8>&- || :
            # The durable reporter remains available if rollback removes the
            # package agent. Recovery never waits for network connectivity.
            if [ -f "$SUP/runtime/bin/xkop-fleet" ] && [ -f "$STATE/enabled" ] &&
                [ -f "$STATE/jobs/current.json" ] && [ "$(uptime_seconds)" -ge "$next_report" ] &&
                [ "$(jq -r .action "$STATE/jobs/current.json")" = install_update ]; then
                next_report=$(($(uptime_seconds) + 60))
                XKOP_FLEET_JOBS_LIB="$SUP/runtime/lib/fleet-jobs.sh" \
                XKOP_FLEET_INSTALL_LIB="$SUP/runtime/lib/fleet-install.sh" \
                XKOP_FLEET_UPDATE_LIB="$SUP/runtime/lib/fleet-update.sh" \
                    sh "$SUP/runtime/bin/xkop-fleet" jobs 8>&- >/dev/null 2>&1 || :
            fi
            sleep 5 8>&-
        done
        ;;
    queue|run|ack)
        exec 7> "$SUP/control.lock"
        for attempt in 1 2 3; do
            flock -n 7 && break
            [ "$attempt" -lt 3 ] || fail 'supervisor busy'
            sleep 1 7>&-
        done
        case "$1" in
            queue)
                [ "$#" -eq 5 ] || fail 'queue HASH INSTALL_TIMEOUT RECOVERY_TIMEOUT JOB_ID'
                if ! pin_valid "$2" || ! duration_valid "$3" || ! duration_valid "$4"; then fail 'invalid queue parameters'; fi
                job_valid "$5" || fail 'invalid job id'
                [ -f "$STATE/enabled" ] && [ -f "$STATE/allow-install" ] || fail 'installation disabled'
                for pending in "$SUP/queue.json" "$SUP/active.json"; do
                    if [ -f "$pending" ] && [ "$(jq -r .job_id "$pending")" = "$5" ]; then
                        [ "$(jq -r .pin "$pending")" = "$2" ] || fail 'job conflicts'
                        exit 0
                    fi
                done
                [ ! -e "$SUP/queue.json" ] || fail 'another queued job'
                (exec 9> "$STATE/transaction.lock"; flock -n 9) || fail 'transaction busy'
                retire_previous
                jq -nc --arg pin "$2" --argjson timeout "$3" --argjson recovery "$4" \
                    --arg job "$5" '{pin:$pin,job_id:$job,timeout:$timeout,recovery_timeout:$recovery}' > "$SUP/queue.json.new"
                mv "$SUP/queue.json.new" "$SUP/queue.json"
                sync
                ;;
            ack)
                if [ "$#" -ne 2 ] || ! job_valid "$2"; then fail 'invalid acknowledgement'; fi
                [ -f "$SUP/active.json" ] && [ "$(jq -r .job_id "$SUP/active.json")" = "$2" ] || fail 'job mismatch'
                manual=0
                case "$(jq -r .state "$SUP/status.json" 2>/dev/null || :)" in
                    recovery_interrupted|recovery_integrity_failed|recovery_failed|invalid_journal|invalid_session|session_identity_lost|session_cleanup_failed) manual=1;;
                esac
                if [ "$manual" -eq 1 ]; then
                    : # Acknowledge reporting only; recovery/queue remain blocked.
                elif [ -f "$SUP/session.json" ]; then fail 'worker still active'
                elif [ -f "$TX/journal.json" ]; then
                    case "$(jq -r .state "$TX/journal.json")" in committed|rolled_back|recovery_failed) ;; *) fail 'not terminal';; esac
                else
                    [ "$(jq -r .state "$SUP/status.json")" = start_interrupted_before_arm ] || fail 'not terminal'
                fi
                printf '%s\n' "$2" > "$SUP/acknowledged.new"
                mv "$SUP/acknowledged.new" "$SUP/acknowledged"
                sync
                ;;
            run) run_once;;
        esac
        ;;
    *) fail 'usage: queue HASH SECONDS SECONDS | run | serve';;
esac
