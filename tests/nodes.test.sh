#!/bin/sh
# Разбор ответа балансировщика.
#
# Образцы вывода сняты с живого движка Xray 26.3.27: он печатает таблицу для
# человека, и единственный надёжный способ её читать — по заголовкам блоков.

set -u

ROOT=${ROOT:-$(dirname "$0")/..}
LIB="$ROOT/xkop/files/usr/lib/xkop"

# shellcheck source=/dev/null
. "$LIB/constants.sh"
# shellcheck source=/dev/null
. "$LIB/logging.sh"
# shellcheck source=/dev/null
. "$LIB/nodes.sh"

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

# Автоматический выбор, живых узлов нет: оба блока пустые.
auto='  - Selecting Override:
    1
  - Selects:
    1'

# Узел закреплён вручную.
manual='  - Selecting Override:
    1   NL-Amsterdam-2
  - Selects:
    1                 '

# Балансировщик выбрал узел сам.
selected='  - Selecting Override:
    1
  - Selects:
    1   DE-Frankfurt-1'

check "пустой перехват читается как пустой" "" \
    "$(nodes_balancer_field "$auto" 'Selecting Override')"
check "пустой выбор читается как пустой" "" \
    "$(nodes_balancer_field "$auto" 'Selects')"

check "закреплённый узел найден" "NL-Amsterdam-2" \
    "$(nodes_balancer_field "$manual" 'Selecting Override')"
check "при закреплении выбор пуст" "" \
    "$(nodes_balancer_field "$manual" 'Selects')"

check "выбранный узел найден" "DE-Frankfurt-1" \
    "$(nodes_balancer_field "$selected" 'Selects')"
check "при автовыборе перехвата нет" "" \
    "$(nodes_balancer_field "$selected" 'Selecting Override')"

# Блоки не должны перетекать один в другой: заголовок следующего обрывает
# чтение предыдущего, иначе закреплённый узел показался бы выбранным.
check "блоки не смешиваются" "NL-Amsterdam-2" \
    "$(nodes_balancer_field "$manual" 'Selecting Override')"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
