#!/bin/bash
set -euo pipefail

# -----------------------------
# Настройки по умолчанию
# -----------------------------
ITERATIONS=10
OUT_DIR="redis_benchmark_results"

HOST="127.0.0.1"
PORT="6379"

REQUESTS=1000000
CLIENTS=50
KEYSPACE=1000000
DATA_SIZE=64

# Кол-во запросов для warm-up перед измерением GET.
# Можно поставить 0, если прогрев не нужен.
WARMUP_REQUESTS=100000

# -----------------------------
# Разбор аргументов
# -----------------------------
usage() {
    cat <<EOF
Usage:
  $0 [options]

Options:
  -i ITERATIONS   Кол-во запусков benchmark, default: $ITERATIONS
  -o OUT_DIR      Каталог для результатов, default: $OUT_DIR
  -h HOST         Redis host, default: $HOST
  -p PORT         Redis port, default: $PORT
  -n REQUESTS     Кол-во запросов на один benchmark, default: $REQUESTS
  -c CLIENTS      Кол-во параллельных клиентов, default: $CLIENTS
  -r KEYSPACE     Размер пространства ключей, default: $KEYSPACE
  -d DATA_SIZE    Размер значения в байтах, default: $DATA_SIZE
  -w WARMUP       Кол-во warm-up GET запросов, default: $WARMUP_REQUESTS

Example:
  $0 -i 10 -n 1000000 -c 50 -r 1000000 -d 64
EOF
}

while getopts ":i:o:h:p:n:c:r:d:w:" opt; do
    case "$opt" in
        i) ITERATIONS="$OPTARG" ;;
        o) OUT_DIR="$OPTARG" ;;
        h) HOST="$OPTARG" ;;
        p) PORT="$OPTARG" ;;
        n) REQUESTS="$OPTARG" ;;
        c) CLIENTS="$OPTARG" ;;
        r) KEYSPACE="$OPTARG" ;;
        d) DATA_SIZE="$OPTARG" ;;
        w) WARMUP_REQUESTS="$OPTARG" ;;
        *) usage; exit 1 ;;
    esac
done

# -----------------------------
# Проверки
# -----------------------------
command -v redis-benchmark >/dev/null 2>&1 || {
    echo "Ошибка: redis-benchmark не найден в PATH" >&2
    exit 1
}

command -v redis-cli >/dev/null 2>&1 || {
    echo "Ошибка: redis-cli не найден в PATH" >&2
    exit 1
}

if ! redis-cli -h "$HOST" -p "$PORT" PING >/dev/null 2>&1; then
    echo "Ошибка: Redis недоступен на $HOST:$PORT" >&2
    exit 1
fi

mkdir -p "$OUT_DIR/set"
mkdir -p "$OUT_DIR/get"

SUMMARY_FILE="$OUT_DIR/summary.csv"
RUNS_FILE="$OUT_DIR/runs.csv"

echo "operation,iterations,avg_requests_per_sec,min_requests_per_sec,max_requests_per_sec" > "$SUMMARY_FILE"
echo "operation,iteration,requests_per_sec,file" > "$RUNS_FILE"

# -----------------------------
# Вспомогательные функции
# -----------------------------
flush_redis() {
    redis-cli -h "$HOST" -p "$PORT" FLUSHALL >/dev/null
}

extract_rps() {
    local csv_file="$1"

    # redis-benchmark --csv обычно пишет строки вида:
    # "SET","123456.78"
    # "GET","234567.89"
    awk -F',' '
        NR == 1 {
            gsub(/"/, "", $2)
            print $2
        }
    ' "$csv_file"
}

calc_stats() {
    local operation="$1"

    awk -F',' -v op="$operation" '
        $1 == op {
            count++
            sum += $3
            if (count == 1 || $3 < min) min = $3
            if (count == 1 || $3 > max) max = $3
        }
        END {
            if (count > 0) {
                printf "%s,%d,%.2f,%.2f,%.2f\n", op, count, sum / count, min, max
            }
        }
    ' "$RUNS_FILE" >> "$SUMMARY_FILE"
}

run_set_benchmark() {
    local iter="$1"
    local out_file="$OUT_DIR/set/set_${iter}.csv"

    flush_redis

    redis-benchmark \
        -h "$HOST" \
        -p "$PORT" \
        -t set \
        -n "$REQUESTS" \
        -c "$CLIENTS" \
        -r "$KEYSPACE" \
        -d "$DATA_SIZE" \
        --csv > "$out_file"

    local rps
    rps="$(extract_rps "$out_file")"

    echo "set,$iter,$rps,$out_file" >> "$RUNS_FILE"
    echo "SET run $iter/$ITERATIONS: $rps req/sec"
}

prefill_for_get() {
    flush_redis

    redis-benchmark \
        -h "$HOST" \
        -p "$PORT" \
        -t set \
        -n "$REQUESTS" \
        -c "$CLIENTS" \
        -r "$KEYSPACE" \
        -d "$DATA_SIZE" \
        -q >/dev/null
}

warmup_get() {
    if [[ "$WARMUP_REQUESTS" -gt 0 ]]; then
        redis-benchmark \
            -h "$HOST" \
            -p "$PORT" \
            -t get \
            -n "$WARMUP_REQUESTS" \
            -c "$CLIENTS" \
            -r "$KEYSPACE" \
            -d "$DATA_SIZE" \
            -q >/dev/null
    fi
}

run_get_benchmark() {
    local iter="$1"
    local out_file="$OUT_DIR/get/get_${iter}.csv"

    prefill_for_get
    warmup_get

    redis-benchmark \
        -h "$HOST" \
        -p "$PORT" \
        -t get \
        -n "$REQUESTS" \
        -c "$CLIENTS" \
        -r "$KEYSPACE" \
        -d "$DATA_SIZE" \
        --csv > "$out_file"

    local rps
    rps="$(extract_rps "$out_file")"

    echo "get,$iter,$rps,$out_file" >> "$RUNS_FILE"
    echo "GET run $iter/$ITERATIONS: $rps req/sec"
}

# -----------------------------
# Основной сценарий
# -----------------------------
echo "Redis benchmark SET/GET"
echo "Host:       $HOST"
echo "Port:       $PORT"
echo "Iterations: $ITERATIONS"
echo "Requests:   $REQUESTS"
echo "Clients:    $CLIENTS"
echo "Keyspace:   $KEYSPACE"
echo "Data size:  $DATA_SIZE"
echo "Out dir:    $OUT_DIR"
echo

echo "=== SET benchmark ==="
for i in $(seq 1 "$ITERATIONS"); do
    run_set_benchmark "$i"
done

echo
echo "=== GET benchmark with prefill SET ==="
for i in $(seq 1 "$ITERATIONS"); do
    run_get_benchmark "$i"
done

calc_stats "set"
calc_stats "get"

echo
echo "=== Summary ==="
column -s, -t "$SUMMARY_FILE" || cat "$SUMMARY_FILE"

echo
echo "Готово."
echo "Все прогоны: $RUNS_FILE"
echo "Средние значения: $SUMMARY_FILE"
echo "CSV SET: $OUT_DIR/set/"
echo "CSV GET: $OUT_DIR/get/"