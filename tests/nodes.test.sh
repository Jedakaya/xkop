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

# Закрепление сильнее стратегии, и показывать надо его.
#
# "Selects" в ответе движка — выбор стратегии, а не то, куда идёт трафик.
# Проверено на живом движке 26.3.27: при закреплении в журнале доступа стоит
# закреплённый узел, а "Selects" показывает другой, самый быстрый. Показывая
# "Selects", интерфейс убеждал человека, что его выбор игнорируют.
JQ=${JQ:-jq}

both='  - Selecting Override:
    1   FI
  - Selects:
    1   DE'

nodes_api() { printf '%s' "$both"; }

sel=$(nodes_selection_json)
check "при закреплении показывается закреплённый" "FI"     "$(printf '%s' "$sel" | "$JQ" -r '.selected')"
check "выбор стратегии виден отдельно" "DE"     "$(printf '%s' "$sel" | "$JQ" -r '.strategy_would_pick')"
check "и это названо ручным" "manual"     "$(printf '%s' "$sel" | "$JQ" -r '.selection')"

# Прежняя сборка движка при закреплении оставляла "Selects" пустым. Работать
# должно и так: показывается всё равно закреплённый.
nodes_api() { printf '%s' "$manual"; }
sel=$(nodes_selection_json)
check "и когда движок молчит про выбор стратегии" "NL-Amsterdam-2"     "$(printf '%s' "$sel" | "$JQ" -r '.selected')"

# Без закрепления показывается то, что выбрала стратегия.
#
# Имя переменной нарочно своё: внутри nodes_selection_json есть локальная
# "selected", и заглушка, читающая её, получила бы пустоту вместо образца.
auto_only="$selected"
nodes_api() { printf '%s' "$auto_only"; }
sel=$(nodes_selection_json)
check "без закрепления показывается выбор стратегии" "DE-Frankfurt-1"     "$(printf '%s' "$sel" | "$JQ" -r '.selected')"
check "и это названо автоматическим" "auto"     "$(printf '%s' "$sel" | "$JQ" -r '.selection')"

echo "$((total - failed))/$total"

[ "$failed" -eq 0 ]
