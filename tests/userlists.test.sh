#!/bin/sh
# Пользовательские списки: то, что человек ведёт сам — файл с подсетями банка,
# ссылка на чужой список.
#
# Главное здесь — что мусор не становится правилом маршрутизации. Страница
# провайдерской заглушки вместо списка разбирается как текст, и без отбора
# строк её содержимое уехало бы в конфигурацию движка.

set -u

ROOT=${ROOT:-$(dirname "$0")/..}
LIB="$ROOT/xkop/files/usr/lib/xkop"

XKOP_LIB_DIR="$LIB"
# shellcheck source=/dev/null
. "$LIB/constants.sh"
XKOP_LIB_DIR="$LIB"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
XKOP_STATE_DIR="$work/state"
XKOP_RUN_DIR="$work/run"
XKOP_CONFIG=xkop

# shellcheck source=/dev/null
. "$LIB/logging.sh"
# shellcheck source=/dev/null
. "$LIB/subscription.sh"
# shellcheck source=/dev/null
. "$LIB/userlists.sh"

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

cat > "$work/domains.lst" << 'EOF'
# список доменов
example.com

  spaced.example.org
не-домен!!
another.example.net   # хвостовой комментарий
EOF

cat > "$work/subnets.lst" << 'EOF'
# подсети
203.0.113.0/24
198.51.100.7
не подсеть
2001:db8::/32
EOF

cat > "$work/portal.html" << 'EOF'
<html><head><title>Вход в сеть</title></head>
<body>Оплатите доступ</body></html>
EOF

check "домены отобраны" "example.com spaced.example.org another.example.net" \
    "$(userlist_clean_domains "$work/domains.lst" | tr '\n' ' ' | sed 's/ *$//')"
check "подсети отобраны" "203.0.113.0/24 198.51.100.7" \
    "$(userlist_clean_subnets "$work/subnets.lst" | tr '\n' ' ' | sed 's/ *$//')"

# IPv6 пока не берём: правила по адресам у нас IPv4, и молча подсунуть движку
# то, чего он в этом правиле не ждёт, хуже, чем не взять.
check "IPv6 в подсети не попал" "0" \
    "$(userlist_clean_subnets "$work/subnets.lst" | grep -c ':' || true)"

check "страница заглушки не даёт подсетей" "0" \
    "$(userlist_clean_subnets "$work/portal.html" | wc -l | tr -d ' ')"

# А вот доменный отбор на HTML обязан споткнуться: теги не проходят проверку
# на имя, и в списке остаётся пусто или почти пусто.
check "страница заглушки не даёт доменов" "0" \
    "$(userlist_clean_domains "$work/portal.html" | wc -l | tr -d ' ')"

# Имя файла кэша выводится из адреса и не меняется от запуска к запуску.
check "имя кэша устойчиво" "yes" \
    "$([ "$(userlist_cache_path 'https://example.com/a.lst')" = "$(userlist_cache_path 'https://example.com/a.lst')" ] && echo yes || echo no)"
check "разные адреса — разные файлы" "yes" \
    "$([ "$(userlist_cache_path 'https://example.com/a.lst')" != "$(userlist_cache_path 'https://example.com/b.lst')" ] && echo yes || echo no)"

# Пустой результат разбора не заменяет рабочий кэш.
mkdir -p "$XKOP_USERLIST_DIR"
target=$(userlist_cache_path 'https://example.com/list.lst')
printf 'good.example.com\n' > "$target"
curl() { cp "$work/portal.html" "$3" 2> /dev/null || return 1; return 0; }
userlist_fetch 'https://example.com/list.lst' domains > /dev/null 2>&1
check "мусор не затирает рабочий список" "good.example.com" "$(cat "$target")"

# --- список приехал документом JSON ----------------------------------------
#
# Официальные списки CDN отдаются документом, и формы у всех разные. Живой
# роутер упёрся в это буквально: адреса Fastly пришлось вписывать в uci
# руками, потому что подключить их ссылкой было нельзя, а без них телефон
# не открывал ни App Store, ни downdetector.

cat > "$work/fastly.json" << 'JSON'
{"addresses": ["23.235.32.0/20", "151.101.0.0/16"],
 "ipv6_addresses": ["2a04:4e42::/32"]}
JSON

userlist_flatten_json "$work/fastly.json"
check "из документа Fastly взяты адреса" "2"     "$(userlist_clean_subnets "$work/fastly.json" | wc -l | tr -d ' ')"
check "адрес на месте" "yes"     "$(userlist_clean_subnets "$work/fastly.json" | grep -q '^151\.101\.0\.0/16$' && echo yes || echo no)"

# Форма Google: адреса лежат в объектах, а не в массиве строк.
cat > "$work/google.json" << 'JSON'
{"prefixes": [{"ipv4Prefix": "8.8.4.0/24"}, {"ipv6Prefix": "2001:4860::/32"},
              {"ipv4Prefix": "8.8.8.0/24"}]}
JSON

userlist_flatten_json "$work/google.json"
check "из вложенных объектов тоже" "2"     "$(userlist_clean_subnets "$work/google.json" | wc -l | tr -d ' ')"

# Обычный текстовый список не трогаем вовсе.
printf '1.2.3.0/24
4.5.6.0/24
' > "$work/plain.lst"
check "текстовый список не документ" "no"     "$(userlist_flatten_json "$work/plain.lst" && echo yes || echo no)"
check "текстовый список не испорчен" "2"     "$(userlist_clean_subnets "$work/plain.lst" | wc -l | tr -d ' ')"

# Документ без единой пригодной строки не должен подменять файл на пустой.
printf '{"note": "ничего полезного"}
' > "$work/empty.json"
userlist_flatten_json "$work/empty.json" > /dev/null 2>&1
check "бесполезный документ не даёт подсетей" "0"     "$(userlist_clean_subnets "$work/empty.json" | wc -l | tr -d ' ')"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
