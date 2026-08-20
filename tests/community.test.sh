#!/bin/sh
# Подсети списков сообщества.
#
# Часть сервисов недостижима по имени в принципе: клиент Telegram ходит
# на захардкоженные адреса, и правило по домену там ловить нечего. Добавленный
# в профиль список при этом выглядит настроенным и не делает ничего — ровно
# это и случилось на живом роутере.
#
# geosite.dat отдаёт только имена, адреса лежат отдельными файлами. Проверяется
# то, что их находят, читают и доносят до правил.

set -u

ROOT=${ROOT:-$(dirname "$0")/..}
JQ=${JQ:-jq}

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

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

XKOP_CACHE_DIR="$work/cache"
XKOP_RUN_DIR="$work/run"
XKOP_CONFIG=xkop
export XKOP_CACHE_DIR XKOP_RUN_DIR XKOP_CONFIG
mkdir -p "$XKOP_CACHE_DIR" "$XKOP_RUN_DIR"

log_warn() { :; }
log_info() { :; }
log_error() { :; }

# shellcheck source=/dev/null
. "$ROOT/xkop/files/usr/lib/xkop/lists.sh"

# --- какие категории вообще имеют подсети ---------------------------------

check "у telegram подсети есть" "yes" \
    "$(lists_subnet_has telegram && echo yes || echo no)"
check "у meta подсети есть" "yes" \
    "$(lists_subnet_has meta && echo yes || echo no)"
check "у youtube подсетей нет" "no" \
    "$(lists_subnet_has youtube && echo yes || echo no)"
check "у russia-inside подсетей нет" "no" \
    "$(lists_subnet_has russia-inside && echo yes || echo no)"

# geosite пишет имена через дефис, файлы подсетей — через подчёркивание.
# Промах здесь означал бы вечный 404 и запись в журнале вместо маршрутизации.
check "имя файла с подчёркиванием" "google_meet" "$(lists_subnet_name google-meet)"
check "у google-meet подсети есть" "yes" \
    "$(lists_subnet_has google-meet && echo yes || echo no)"

# --- чтение кэша ----------------------------------------------------------

mkdir -p "$(lists_subnet_dir)"
cat > "$(lists_subnet_path telegram)" << 'EOF'
# комментарий, который не подсеть
5.28.192.0/18
149.154.160.0/20

не подсеть вовсе
91.108.4.0/22
EOF

check "подсети прочитаны" "3" "$(lists_subnet_entries telegram | wc -l | tr -d ' ')"
check "комментарий отброшен" "no" \
    "$(lists_subnet_entries telegram | grep -q '^#' && echo yes || echo no)"
check "мусор отброшен" "no" \
    "$(lists_subnet_entries telegram | grep -q 'не подсеть' && echo yes || echo no)"
check "адрес на месте" "yes" \
    "$(lists_subnet_entries telegram | grep -q '^149\.154\.160\.0/20$' && echo yes || echo no)"

check "у категории без файла подсетей нет" "0" \
    "$(lists_subnet_entries discord | wc -l | tr -d ' ')"

# --- подсети доходят до правила -------------------------------------------

# Профиль собирается тем же кодом, что и на роутере, но uci подменён: важно
# не то, как читается конфигурация, а то, что адреса попадают в правило рядом
# с доменами.
subscription_config_list() { printf 'telegram\nyoutube\n'; }
config_uci_get() { :; }
config_uci_list_json() { printf '[]'; }
userlist_entries_json() { printf '[]'; }

# shellcheck source=/dev/null
. "$ROOT/xkop/files/usr/lib/xkop/config.sh"

subnets=$(config_community_subnets_json blocked_ru)
check "подсети категории собраны" "3" "$(printf '%s' "$subnets" | "$JQ" 'length')"
check "адрес Telegram среди них" "true" \
    "$(printf '%s' "$subnets" | "$JQ" 'any(. == "149.154.160.0/20")')"

profile=$(config_profile_json blocked_ru)
check "подсети попали в профиль" "true" \
    "$(printf '%s' "$profile" | "$JQ" '.subnet | any(. == "5.28.192.0/18")')"

# Правило по адресам строится из тех же подсетей, что и раньше из ручных:
# отдельного пути для списков сообщества нет, и появиться он не должен.
rules=$(printf '%s' "$profile" | "$JQ" -c '{settings: {}, pool: [], bindings: [{order: 10, profile: ., channel: {type: "direct"}}]}' \
    | "$JQ" -f "$ROOT/xkop/files/usr/lib/xkop/config.jq" 2> /dev/null)
check "адреса стали правилом маршрутизации" "true" \
    "$(printf '%s' "$rules" | "$JQ" '[.routing.rules[] | select(.ip? != null) | .ip[]] | any(. == "149.154.160.0/20")')"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
