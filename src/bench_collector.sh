#!/bin/bash
set -euo pipefail

RUNS=10
OUT_DIR="${1:-redis_benchmark_results}"

mkdir -p "$OUT_DIR"

for i in $(seq -w 1 "$RUNS"); do
    OUT_FILE="$OUT_DIR/benchmark_${i}.csv"

    echo "Запуск $i/$RUNS -> $OUT_FILE"

    ./redis-benchmark --csv > "$OUT_FILE"
done

echo "Готово. Результаты сохранены в: $OUT_DIR"