#!/bin/sh
# Retry failed GitHub connections without replacing the current file on failure.
set -u
ROOT=${ROOT:-$(dirname "$0")/..}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed -n '/^download()/,/^}/p' "$ROOT/install.sh" > "$work/function.sh"
. "$work/function.sh"
failed=0
check() {
    if [ "$2" = "$3" ]; then echo "ok   $1"; else
        echo "FAIL $1: expected '$2', got '$3'"; failed=$((failed + 1))
    fi
}
note() { :; }; warn() { :; }
run_bounded() { shift; "$@"; }
export DOWNLOAD_TEST_WORK="$work"
mkdir -p "$work/bin"
printf '#!/bin/sh\nprintf "Name: github.com\\nAddress: 192.0.2.10\\n"\n' > "$work/bin/nslookup"
chmod +x "$work/bin/nslookup"
PATH="$work/bin:$PATH"; export PATH
nslookup() {
    printf 'Server: 1.1.1.1\nAddress: 1.1.1.1:53\n\nName: github.com\nAddress: 192.0.2.10\n'
}
curl() {
    printf '%s\n' "$*" >> "$work/curl-calls"
    curl_target=''; curl_resolved=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -o) shift; curl_target="$1" ;;
            --resolve) curl_resolved=1 ;;
        esac
        shift
    done
    printf partial > "$curl_target"
    if [ "$curl_resolved" = 1 ] && [ "${DOWNLOAD_TEST_FAIL:-0}" = 0 ]; then
        printf complete > "$curl_target"; return 0
    fi
    return 28
}
printf original > "$work/target"
download https://github.com/example/release "$work/target"; rc=$?
check "альтернативный адрес после тайм-аута" 0 "$rc"
check "полная загрузка установлена" complete "$(cat "$work/target")"
check "TLS не отключается" 0 "$(grep -Ec -- '--insecure|(^| )-k( |$)' "$work/curl-calls")"
check "проверен альтернативный IP" yes "$(grep -q -- '--resolve github.com:443:192.0.2.10' "$work/curl-calls" && echo yes || echo no)"
check "DNS перенаправления релиза тоже обходится" yes "$(grep -q -- '--resolve release-assets.githubusercontent.com:443:192.0.2.10' "$work/curl-calls" && echo yes || echo no)"
DOWNLOAD_TEST_FAIL=1
printf original > "$work/target"
download https://github.com/example/release "$work/target"; rc=$?
check "полный отказ возвращает ошибку" 1 "$rc"
check "отказ сохраняет исходный файл" original "$(cat "$work/target")"
[ "$failed" -eq 0 ]
