#!/bin/sh
# Превращение ссылки из подписки в исходящее Xray.
#
# Проверяется не только удачный путь, но и отбраковка: сочетание, которое
# движок откажется собрать, обязано быть отброшено здесь, потому что
# отвергнутая конфигурация означает роутер без движка.

set -u

ROOT=${ROOT:-$(dirname "$0")/..}
JQ=${JQ:-jq}
PROGRAM="$ROOT/xkop/files/usr/lib/xkop/subscription.jq"
LINKS="$ROOT/tests/fixtures/subscription/links.txt"

if ! command -v "$JQ" > /dev/null 2>&1 && [ ! -x "$JQ" ]; then
    echo "jq not found: $JQ" >&2
    exit 2
fi

failed=0
total=0

check() {
    local label="$1" expected="$2" actual="$3"
    total=$((total + 1))
    if [ "$expected" = "$actual" ]; then
        echo "ok   $label"
    else
        echo "FAIL $label"
        echo "     ожидалось: $expected"
        echo "     получено:  $actual"
        failed=$((failed + 1))
    fi
}

out=$("$JQ" -R -s -c --arg mode links --arg subscription main --arg format link-list \
    -f "$PROGRAM" "$LINKS")

q() { printf '%s' "$out" | "$JQ" -c "$1"; }

# Найти сервер по тегу.
by_tag() { printf '%s' "$out" | "$JQ" -c --arg tag "$1" '.servers[] | select(.tag == $tag) | '"$2"; }

check "разобрано серверов" "8" "$(q '.servers | length')"
check "отброшено ссылок" "6" "$(q '.skipped | length')"

check "ws: путь раскодирован и ранние данные в запросе" '"/ws?ed=2048"' \
    "$(by_tag NL-Amsterdam-2 '.outbound.streamSettings.wsSettings.path')"
check "ws: хост перенесён" '"nl2.example.com"' \
    "$(by_tag NL-Amsterdam-2 '.outbound.streamSettings.wsSettings.host')"
check "tls: имя сервера из sni" '"nl2.example.com"' \
    "$(by_tag NL-Amsterdam-2 '.outbound.streamSettings.tlsSettings.serverName')"
check "vless: шифрование обязательно" '"none"' \
    "$(by_tag NL-Amsterdam-2 '.outbound.settings.vnext[0].users[0].encryption')"

check "имя узла раскодировано из процентов" "true" \
    "$(q '[.servers[].tag] | index("Нидерланды") != null')"

check "xhttp: путь и режим на месте" '["/xh","auto"]' \
    "$(by_tag XHTTP-1 '[.outbound.streamSettings.xhttpSettings.path, .outbound.streamSettings.xhttpSettings.mode]')"
check "xhttp: пустой хост не попал в настройки" "false" \
    "$(by_tag XHTTP-1 '.outbound.streamSettings.xhttpSettings | has("host")')"
check "grpc: multiMode из mode=multi" "true" \
    "$(by_tag GRPC-1 '.outbound.streamSettings.grpcSettings.multiMode')"
check "IPv6 адрес без скобок" '"2001:db8::1"' \
    "$(by_tag IPv6-1 '.address')"

check "hysteria2 это протокол hysteria" '"hysteria"' \
    "$(by_tag FI-Helsinki-3 '.outbound.protocol')"
check "hysteria2: версия в настройках" "2" \
    "$(by_tag FI-Helsinki-3 '.outbound.settings.version')"
check "hysteria2: пароль продублирован в транспорт" '"s3cr3t-pass"' \
    "$(by_tag FI-Helsinki-3 '.outbound.streamSettings.hysteriaSettings.auth')"
check "hysteria2: отпечаток uTLS не проставлен" "true" \
    "$(by_tag FI-Helsinki-3 '(.outbound.streamSettings.tlsSettings.fingerprint // null) == null')"
check "hysteria2: обфускация отмечена как неучтённая" '["obfs_ignored"]' \
    "$(by_tag FI-Helsinki-3 '.notes')"

check "socks5: учётные данные разобраны" '{"user":"user","pass":"pass"}' \
    "$(by_tag Socks5 '.outbound.settings.servers[0].users[0]')"
check "старый формат shadowsocks разобран" '["se1.example.com",8388,"aes-256-gcm"]' \
    "$(by_tag SE-Stockholm-legacy '[.address, .port, .outbound.settings.servers[0].method]')"

reason() { printf '%s' "$out" | "$JQ" -r --arg part "$1" '.skipped[] | select(.link | contains($part)) | .reason'; }

check "reality поверх ws отброшен" "reality_needs_raw_xhttp_or_grpc" "$(reason 'rw.example.com')"
check "удалённый транспорт h2 отброшен" "unsupported_transport" "$(reason 'h2.example.com')"
check "vmess пока не поддержан" "unsupported_scheme" "$(reason 'vmess://')"
check "socks4 отброшен" "unsupported_scheme" "$(reason 'socks4://')"
check "ссылка без порта отброшена" "no_port" "$(reason 'noport.example.com')"
check "мусорная строка отброшена" "unreadable" "$(reason 'мусора')"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
