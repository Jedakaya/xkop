#!/bin/sh
# Диагностика: что она говорит и, главное, чего не говорит.
#
# Проверяется правило, ради которого всё это писалось: не показывать зелёное
# там, где не проверяли, и не называть причину, которую не установили.
# Окружение подменяется переопределением функций — так проверяется решение,
# а не роутер под тестом.

set -u

ROOT=${ROOT:-$(dirname "$0")/..}
LIB="$ROOT/xkop/files/usr/lib/xkop"

XKOP_LIB_DIR="$LIB"
# shellcheck source=/dev/null
. "$LIB/constants.sh"
XKOP_LIB_DIR="$LIB"
XKOP_RUN_DIR=$(mktemp -d)
trap 'rm -rf "$XKOP_RUN_DIR"' EXIT

# shellcheck source=/dev/null
. "$LIB/logging.sh"
# shellcheck source=/dev/null
. "$LIB/nft.sh"
# shellcheck source=/dev/null
. "$LIB/diagnostics.sh"

failed=0
total=0

check() {
    local label="$1" expected="$2" actual="$3"
    total=$((total + 1))
    if [ "$expected" = "$actual" ]; then
        echo "ok   $label"
    else
        echo "FAIL $label: ожидалось '$expected', получено '$actual'"
        failed=$((failed + 1))
    fi
}

# --- правила nft ---------------------------------------------------------

nft_present() { return 1; }
check "правил нет — так и сказано" "правил нет" "$(diag_nft_json | jq -r '.state')"
check "и никакого зелёного" "false" "$(diag_nft_json | jq -r '.rules_present')"

nft_present() { return 0; }
nft() { echo "        counter packets 0 bytes 0"; }
check "правила есть, но трафика не было" "правила есть, трафик через них ещё не шёл" \
    "$(diag_nft_json | jq -r '.state')"

nft() { echo "        counter packets 1200 bytes 900000"; echo "        counter packets 300 bytes 1000"; }
check "трафик через правила шёл" "правила работают" "$(diag_nft_json | jq -r '.state')"
check "пакеты просуммированы" "1500" "$(diag_nft_json | jq -r '.packets_seen')"

# --- поддельные адреса ---------------------------------------------------

config_uci_get() { [ "$2" = "dns_mode" ] && echo "off"; }
check "выключенный режим не проверяется" "false" "$(diag_fakeip_json | jq -r '.checked')"

config_uci_get() { [ "$2" = "dns_mode" ] && echo "fakeip"; }
subscription_pool_all() { echo '[]'; }

canary_addresses() { echo "198.18.3.41"; }
check "поддельный адрес опознан" "true" "$(diag_fakeip_json | jq -r '.fake')"

canary_addresses() { echo "64.226.122.113"; }
check "настоящий адрес не выдаётся за поддельный" "false" "$(diag_fakeip_json | jq -r '.fake')"

# Наш резолвер молчит. Это «проверить не удалось», а не «сломано» — разница,
# которую в podkop путали трижды.
canary_addresses() { echo ""; }
check "молчание резолвера — не приговор" "false" "$(diag_fakeip_json | jq -r '.checked')"
check "и причина названа честно" "наш резолвер не ответил, проверить не удалось" \
    "$(diag_fakeip_json | jq -r '.state')"

# --- общая строка --------------------------------------------------------

diag_system_json() { echo '{"ok":true}'; }
diag_nft_json() { echo '{"ok":true,"rules_present":true,"packets_seen":10}'; }
diag_dns_json() { echo '{"ok":true,"answered":true}'; }
diag_fakeip_json() { echo '{"ok":true,"mode":"off"}'; }
lists_present() { return 0; }
cmd_subscriptions() { echo '[{"state":"ready","reason":null}]'; }
cmd_check_engine() { echo '{"engine_installed":true}'; }
service_status_json() { echo '{"engine":{"running":true,"answering":true},"nodes":5}'; }

check "всё на месте — так и сказано" "работает" "$(diag_global_json | jq -r '.summary')"

cmd_check_engine() { echo '{"engine_installed":false}'; }
check "нет движка — названо первым" "движок не установлен" "$(diag_global_json | jq -r '.summary')"

cmd_check_engine() { echo '{"engine_installed":true}'; }
service_status_json() { echo '{"engine":{"running":true,"answering":false},"nodes":5}'; }
check "запущен, но не отвечает — это отдельная беда" "движок запущен, но не отвечает" \
    "$(diag_global_json | jq -r '.summary')"

service_status_json() { echo '{"engine":{"running":true,"answering":true},"nodes":5}'; }
cmd_subscriptions() { echo '[{"state":"blocked","reason":"hwid_limit"}]'; }
check "причина берётся у подписки, а не выдумывается" "подписки не готовы: hwid_limit" \
    "$(diag_global_json | jq -r '.summary')"

cmd_subscriptions() { echo '[{"state":"ready","reason":null}]'; }
service_status_json() { echo '{"engine":{"running":true,"answering":true},"nodes":0}'; }
check "без узлов трафик идёт напрямую" "узлов нет, трафик идёт напрямую" \
    "$(diag_global_json | jq -r '.summary')"

service_status_json() { echo '{"engine":{"running":true,"answering":true},"nodes":3}'; }
lists_present() { return 1; }
check "без списков правила по спискам не сработают" \
    "списков доменов нет, правила по спискам не сработают" \
    "$(diag_global_json | jq -r '.summary')"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
