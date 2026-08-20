#!/bin/sh
# Test runner. Executes every tests/*.test.sh and reports a total.
#
# Nothing here needs a router or a running engine: the metrics samples are
# shaped exactly as Xray serves them, and the rest is pure shell.
#
# Usage: sh tests/run.sh
#        JQ=/path/to/jq sh tests/run.sh

set -u

ROOT=$(dirname "$0")/..
export ROOT
export JQ=${JQ:-jq}

# Движок, если он есть: конфигурацию проверяет он, а не мы. Наборы, которым
# он не нужен, эту переменную просто не смотрят.
export XRAY=${XRAY:-xray}

failed=0

for suite in "$ROOT"/tests/*.test.sh; do
    echo "== $(basename "$suite")"
    if sh "$suite"; then
        :
    else
        failed=$((failed + 1))
    fi
done

echo "==="
if [ "$failed" -eq 0 ]; then
    echo "все проверки пройдены"
else
    echo "провалено наборов: $failed"
fi

[ "$failed" -eq 0 ]
