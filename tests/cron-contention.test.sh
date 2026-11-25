#!/bin/sh
set -eu
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export XKOP_RUN_DIR="$work"
export XKOP_STATE_DIR="$work"

# Install the real schedule into an isolated crontab.
sed -e 's@/etc/crontabs/root@'"$work"'/root@g' \
    -e 's@/etc/crontabs@'"$work"'@g' \
    -e 's@/etc/init.d/cron@stub_cron@g' \
    "$ROOT/xkop/files/usr/lib/xkop/service.sh" > "$work/service.sh"
# shellcheck source=/dev/null
. "$work/service.sh"
crontab() { :; }
stub_cron() { :; }
log_info() { :; }
cron_minute() { echo 28; }

printf '%s\n' '13 * * * * /usr/bin/other' > "$work/root"
cron_install
grep -Fxq '13 * * * * /usr/bin/other' "$work/root"
awk '
function includes(spec, minute, parts, limits, step, start, end) {
    split(spec, parts, "/")
    step = parts[2] + 0
    if (!step) return minute == parts[1] + 0
    if (parts[1] == "*") return minute % step == 0
    split(parts[1], limits, "-")
    start = limits[1] + 0
    end = limits[2] + 0
    return minute >= start && minute <= end && (minute - start) % step == 0
}
$2 == "*" && $6 == "/usr/bin/xkop" && ($7 == "keep" || $7 == "canary" || $7 == "access_trim") {
    jobs[$7] = $1
}
END {
    for (m = 0; m < 60; m++) {
        overlap = 0
        for (job in jobs) {
            if (includes(jobs[job], m)) {
                count[job]++
                overlap++
            }
        }
        if (overlap > 1) {
            printf "FAIL more than one work-lock job at minute %02d\n", m
            failures++
        }
    }
    if (count["keep"] != 12 || count["canary"] != 4 || count["access_trim"] != 6) failures++
    exit failures != 0
}
' "$work/root"
echo 'ok periodic Xkop work-lock jobs have distinct start times'
