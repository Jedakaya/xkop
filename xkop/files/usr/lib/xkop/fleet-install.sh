#!/bin/sh
# shellcheck shell=ash disable=SC2154,SC2016
# Local installer setup and device-scoped communication with independent recovery.

fleet_install_enable() {
    [ "$#" -eq 1 ] && [ -f "$1" ] || fail 'enable-updates requires owner health JSON'
    [ "$STATE" = /etc/xkop/fleet ] || fail 'installer requires the standard state directory'
    [ -f "$STATE/enabled" ] && [ -f "$STATE/release.pub" ] || fail 'enrollment and signing key required'
    lock
    for utility in jq curl usign sha256sum tar flock setsid dig nft xray hexdump; do
        command -v "$utility" >/dev/null 2>&1 || fail "missing installer prerequisite: $utility"
    done
    library=${XKOP_FLEET_UPDATE_LIB:-/usr/lib/xkop/fleet-update.sh}
    library=${library%/*}
    # The real baseline is run by the bounded guardian before the transaction
    # is armed. Setup itself only validates the owner's declarative contract.
    XKOP_FLEET_HEALTH_CONFIG="$1" sh "$library/fleet-health.sh" validate || fail 'invalid health contract'
    mkdir -p "$STATE/supervisor"
    [ ! -L "$STATE/supervisor" ] || fail 'unsafe supervisor directory'
    exec 7> "$STATE/supervisor/control.lock"
    flock -n 7 || fail 'supervisor busy'
    sup="$STATE/supervisor"
    [ ! -e "$sup/queue.json" ] && [ ! -e "$sup/session.json" ] || fail 'existing supervisor transaction'
    if [ -e "$sup/active.json" ]; then
        [ -f "$sup/acknowledged" ] && [ "$(cat "$sup/acknowledged")" = "$(jq -r .job_id "$sup/active.json")" ] || fail 'transaction not acknowledged'
        case "$(jq -r .state "$STATE/transaction/journal.json" 2>/dev/null || :)" in
            committed|rolled_back) ;;
            *) fail 'unresolved recovery';;
        esac
    fi
    [ ! -e "$sup/runtime" ] || [ -L "$sup/runtime" ] || fail 'unexpected legacy runtime directory'
    runtime=$(mktemp -d "$STATE/supervisor/.runtime.XXXXXX")
    mkdir "$runtime/bin" "$runtime/lib"
    cp "$0" "$runtime/bin/xkop-fleet"
    cp "$library"/fleet-*.sh "$library/fleet-manifest.jq" "$library/fleet-guardian.init" "$runtime/lib/"
    (cd "$library" && sha256sum fleet-*.sh fleet-manifest.jq fleet-guardian.init) > "$runtime/source.sha256"
    sha256sum "$0" | cut -d ' ' -f 1 > "$runtime/client.sha256"
    cp "$1" "$STATE/health.json.new"
    chmod 600 "$STATE/health.json.new"
    mv "$STATE/health.json.new" "$STATE/health.json"
    # The capability is published only after a complete, running executor exists.
    # A failed setup keeps its pending marker and can safely be retried.
    rm -f "$STATE/allow-install"
    : > "$sup/setup-pending"
    sync
    if [ -x /etc/init.d/xkop-fleet-guardian ]; then
        /etc/init.d/xkop-fleet-guardian stop || fail 'cannot stop previous supervisor'
    fi
    rm -f "$sup/runtime.next"
    ln -s "${runtime##*/}" "$sup/runtime.next"
    mv -fT "$sup/runtime.next" "$sup/runtime"
    # This owner-created service is deliberately outside the package file list:
    # rollback to a pre-agent package must not remove recovery or its reporter.
    cp "$library/fleet-guardian.init" /etc/init.d/xkop-fleet-guardian
    chmod 700 /etc/init.d/xkop-fleet-guardian
    sync
    /etc/init.d/xkop-fleet-guardian enable || fail 'cannot enable supervisor; retry setup'
    /etc/init.d/xkop-fleet-guardian start || fail 'cannot start supervisor; retry setup'
    /etc/init.d/xkop-fleet-guardian running || fail 'supervisor not running; retry setup'
    : > "$STATE/allow-install"
    rm -f "$sup/setup-pending"
    sync
    # No worker can reference a retired runtime: the gate above requires its
    # terminal result to have been acknowledged, and the old service was stopped.
    for retired in "$sup"/.runtime.*; do
        [ "$retired" = "$runtime" ] || [ ! -d "$retired" ] || rm -rf "$retired"
    done
    exec 7>&-
}

fleet_install_refresh() {
    # Only the installed package refreshes the executor. The durable reporter
    # must never replace/stop itself while finishing an older transaction.
    [ "$0" = /usr/bin/xkop-fleet ] || return 0
    [ -f "$STATE/allow-install" ] && [ -f "$STATE/health.json" ] || return 0
    local runtime="$STATE/supervisor/runtime" library=/usr/lib/xkop
    if [ -f "$runtime/source.sha256" ] &&
        (cd "$library" && sha256sum -c "$runtime/source.sha256" >/dev/null 2>&1) &&
        [ "$(sha256sum "$0" | cut -d ' ' -f 1)" = "$(cat "$runtime/client.sha256")" ] &&
        [ -x /etc/init.d/xkop-fleet-guardian ] && /etc/init.d/xkop-fleet-guardian running >/dev/null 2>&1; then
        return 0
    fi
    sh "$0" enable-updates "$STATE/health.json"
}

fleet_install_tick() {
    local sup="$STATE/supervisor" current="$STATE/jobs/current.json" id hash status
    id=$(jq -r .job_id "$current")
    hash=$(jq -r .release.manifest_sha256 "$current")
    if [ ! -f "$sup/runtime/lib/fleet-guardian.sh" ]; then
        fleet_job_event failed install_failed
        return
    fi
    if [ ! -f "$sup/active.json" ] || [ "$(jq -r .job_id "$sup/active.json")" != "$id" ]; then
        [ -f "$STATE/enabled" ] && [ -f "$STATE/allow-install" ] || { fleet_job_event failed install_failed; return; }
        [ "$(date +%s)" -lt "$(jq -r .expires "$current")" ] || { fleet_job_event failed expired; return; }
        # Queue is idempotent on job ID and pin, including after response loss.
        sh "$sup/runtime/lib/fleet-guardian.sh" queue "$hash" 300 180 "$id" || return 1
        return 0
    fi
    [ "$(jq -r .pin "$sup/active.json")" = "$hash" ] || return 1
    status=$(jq -r .state "$sup/status.json" 2>/dev/null || :)
    case "$status" in
        recovery_interrupted|recovery_integrity_failed|recovery_failed|invalid_journal|invalid_session|session_identity_lost|session_cleanup_failed)
            fleet_job_event failed recovery_failed
            return 0
            ;;
    esac
    [ ! -f "$sup/session.json" ] || return 0
    if [ -f "$STATE/transaction/journal.json" ]; then
        [ "$(jq -r .manifest_sha256 "$STATE/transaction/journal.json")" = "$hash" ] || return 1
        status=$(jq -r .state "$STATE/transaction/journal.json")
        case "$status" in
            committed) fleet_job_event installed '';;
            rolled_back) fleet_job_event rolled_back install_failed;;
            recovery_failed)
                fleet_job_event failed recovery_failed;;
        esac
    else
        status=$(jq -r .state "$sup/status.json" 2>/dev/null || :)
        [ "$status" != start_interrupted_before_arm ] || fleet_job_event failed install_failed
    fi
}

fleet_install_ack() {
    local sup="$STATE/supervisor" id
    id=$(jq -r .job_id "$STATE/jobs/current.json")
    # Refusal before queue has no supervisor transaction to acknowledge.
    [ -f "$sup/active.json" ] && [ "$(jq -r .job_id "$sup/active.json")" = "$id" ] || return 0
    sh "$sup/runtime/lib/fleet-guardian.sh" ack "$id"
}
