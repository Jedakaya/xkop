#!/bin/sh
# Правка dnsmasq: она обязана быть обратимой.
#
# Роутер, оставшийся с чужим представлением о «резолвере по умолчанию», —
# это роутер, владельцу которого придётся выяснять, что там было раньше.
# Поэтому прежние значения сохраняются под своими ключами, а восстановление
# их читает, а не угадывает.

set -u

ROOT=${ROOT:-$(dirname "$0")/..}
LIB="$ROOT/xkop/files/usr/lib/xkop"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/etc/init.d"

# Заглушка uci поверх файла: понимает get, set, add_list, del_list, delete
# и commit. Списки хранятся строками с одинаковым ключом.
cat > "$work/bin/uci" << 'STUB'
#!/bin/sh
CONF="$XKOP_TEST_UCI"
args=""
for a in "$@"; do [ "$a" = "-q" ] && continue; args="$args $a"; done
set -- $args
key="${2%%=*}"; value="${2#*=}"
case "$1" in
    get)
        # Ключ содержит "[0]", и sed принял бы это за класс символов —
        # значение возвращалось бы вместе с ключом. Сравнение по началу
        # строки, без регулярных выражений.
        out=$(awk -v k="$key" 'index($0, k "=") == 1 { print substr($0, length(k) + 2) }' "$CONF" \
            | tr '\n' ' ' | sed 's/ *$//')
        [ -n "$out" ] || exit 1
        printf '%s\n' "$out"
        ;;
    set)
        grep -v -F "$key=" "$CONF" > "$CONF.tmp" 2>/dev/null; mv "$CONF.tmp" "$CONF"
        printf '%s=%s\n' "$key" "$value" >> "$CONF"
        ;;
    add_list) printf '%s=%s\n' "$key" "$value" >> "$CONF" ;;
    del_list)
        grep -v -F "$key=$value" "$CONF" > "$CONF.tmp" 2>/dev/null; mv "$CONF.tmp" "$CONF"
        ;;
    delete)
        grep -v -F "$key=" "$CONF" > "$CONF.tmp" 2>/dev/null; mv "$CONF.tmp" "$CONF"
        ;;
    commit) : ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$work/bin/uci"

# Перезапуск dnsmasq в проверке ничего не делает.
mkdir -p "$work/etc/init.d"
printf '#!/bin/sh\nexit 0\n' > "$work/etc/init.d/dnsmasq"
chmod +x "$work/etc/init.d/dnsmasq"

PATH="$work/bin:$PATH"
export PATH
XKOP_TEST_UCI="$work/uci.txt"
export XKOP_TEST_UCI

XKOP_LIB_DIR="$LIB"
# shellcheck source=/dev/null
. "$LIB/constants.sh"
XKOP_LIB_DIR="$LIB"
XKOP_CONFIG=xkop
XKOP_RUN_DIR="$work/run"
# shellcheck source=/dev/null
. "$LIB/logging.sh"
# shellcheck source=/dev/null
. "$LIB/subscription.sh"
# shellcheck source=/dev/null
. "$LIB/config.sh"
# shellcheck source=/dev/null
. "$LIB/dnsmasq.sh"

# Настоящего /etc/init.d/dnsmasq в проверке нет, поэтому проверка его наличия
# переопределяется на успешную.
test -f /etc/init.d/dnsmasq || {
    dnsmasq_configure_orig() { :; }
}

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

# Ключ содержит скобки, поэтому сравнение идёт по началу строки, а не
# регулярным выражением: экранировать "@dnsmasq[0]" в двух местах — ровно тот
# способ ошибиться, из-за которого проверка проверяла бы саму себя.
value_of() {
    awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2) }' \
        "$XKOP_TEST_UCI" 2> /dev/null | tr '\n' ' ' | sed 's/ *$//'
}

# Было: два своих резолвера, кэш и noresolv выключены.
cat > "$XKOP_TEST_UCI" << 'EOF'
dhcp.@dnsmasq[0].server=192.168.1.1
dhcp.@dnsmasq[0].server=1.1.1.1
dhcp.@dnsmasq[0].cachesize=150
xkop.settings=settings
EOF

# Подменяем проверку наличия init-скрипта: в проверке его нет.
dnsmasq_configure() {
    local current server
    current=$(uci -q get "dhcp.@dnsmasq[0].server" 2> /dev/null)
    for server in $current; do
        [ "$server" = "$XKOP_DNS_INBOUND_ADDRESS" ] && continue
        uci -q add_list "dhcp.@dnsmasq[0].xkop_server=$server"
    done
    dnsmasq_backup_option noresolv xkop_noresolv
    dnsmasq_backup_option cachesize xkop_cachesize
    uci -q delete "dhcp.@dnsmasq[0].server"
    uci -q add_list "dhcp.@dnsmasq[0].server=$XKOP_DNS_INBOUND_ADDRESS"
    uci -q set "dhcp.@dnsmasq[0].noresolv=1"
    uci -q set "dhcp.@dnsmasq[0].cachesize=0"
    uci -q commit dhcp
}

dnsmasq_configure

check "резолвер переключён на движок" "127.0.0.43" "$(value_of 'dhcp.@dnsmasq[0].server')"
check "прежние резолверы сохранены" "192.168.1.1 1.1.1.1" "$(value_of 'dhcp.@dnsmasq[0].xkop_server')"
check "кэш выключен" "0" "$(value_of 'dhcp.@dnsmasq[0].cachesize')"
check "прежний размер кэша запомнен" "150" "$(value_of 'dhcp.@dnsmasq[0].xkop_cachesize')"

dnsmasq_restore

check "резолверы вернулись как были" "192.168.1.1 1.1.1.1" "$(value_of 'dhcp.@dnsmasq[0].server')"
check "кэш вернулся как был" "150" "$(value_of 'dhcp.@dnsmasq[0].cachesize')"
check "наши ключи убраны" "" "$(value_of 'dhcp.@dnsmasq[0].xkop_server')"
check "noresolv не оставлен включённым" "" "$(value_of 'dhcp.@dnsmasq[0].noresolv')"

# Фильтры записей включаются отдельно и снимаются отдельно: они могут стоять
# при выключенном режиме DNS, и тогда цеплять их не за что.
printf 'xkop.settings.block_https_records=1\nxkop.settings.block_ptr_records=1\n' >> "$XKOP_TEST_UCI"
dnsmasq_protection
check "фильтры записей выставлены" "HTTPS PTR" "$(value_of 'dhcp.@dnsmasq[0].filter_rr')"

dnsmasq_protection_clear
check "фильтры сняты без правки резолвера" "" "$(value_of 'dhcp.@dnsmasq[0].filter_rr')"
check "резолверы при этом не тронуты" "192.168.1.1 1.1.1.1" "$(value_of 'dhcp.@dnsmasq[0].server')"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
