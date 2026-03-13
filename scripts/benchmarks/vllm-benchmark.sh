#!/bin/bash
# =============================================================================
# vLLM Benchmark Suite — Phase 32 (Stages 205–209)
# =============================================================================
set -euo pipefail

VLLM_HOST="${VLLM_HOST:-localhost}"
VLLM_PORT="${VLLM_PORT:-8000}"
MODEL="${MODEL:-}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/vllm-benchmarks}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  quick         Quick smoke test (5 requests)
  throughput    Throughput benchmark (varying concurrency)
  latency       Latency benchmark (p50/p95/p99)
  stress        Stress test (sustained high load)
  compare       Compare two configurations side-by-side

Environment:
  VLLM_HOST     vLLM server host (default: localhost)
  VLLM_PORT     vLLM server port (default: 8000)
  MODEL         Model name for requests (auto-detected if empty)
  OUTPUT_DIR    Directory for benchmark results

Examples:
  VLLM_PORT=8000 $(basename "$0") quick
  VLLM_PORT=8000 MODEL=Llama-3.1-70B-Instruct $(basename "$0") throughput
EOF
}

# Auto-detect model name
detect_model() {
    if [ -z "$MODEL" ]; then
        MODEL=$(curl -s "http://${VLLM_HOST}:${VLLM_PORT}/v1/models" | jq -r '.data[0].id' 2>/dev/null)
        if [ -z "$MODEL" ] || [ "$MODEL" = "null" ]; then
            echo "ERROR: Cannot detect model. Set MODEL env var."
            exit 1
        fi
    fi
    echo "Model: $MODEL"
}

send_request() {
    local prompt="$1"
    local max_tokens="${2:-100}"

    curl -s -w "\n%{time_total}" \
        -X POST "http://${VLLM_HOST}:${VLLM_PORT}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"${MODEL}\",
            \"messages\": [{\"role\": \"user\", \"content\": \"${prompt}\"}],
            \"max_tokens\": ${max_tokens},
            \"temperature\": 0.1
        }"
}

cmd_quick() {
    detect_model
    echo ""
    echo "=== Quick Smoke Test ==="
    echo "Sending 5 requests..."
    echo ""

    PROMPTS=(
        "What is 2+2?"
        "Explain quantum computing in one sentence."
        "Write a haiku about servers."
        "What is the capital of France?"
        "List 3 programming languages."
    )

    TOTAL_TIME=0
    SUCCESS=0
    FAIL=0

    for i in "${!PROMPTS[@]}"; do
        START=$(date +%s%N)
        RESULT=$(send_request "${PROMPTS[$i]}" 50 2>/dev/null)
        END=$(date +%s%N)
        ELAPSED=$(echo "scale=3; ($END - $START) / 1000000000" | bc)

        if echo "$RESULT" | head -1 | jq -e '.choices[0].message.content' &>/dev/null; then
            TOKENS=$(echo "$RESULT" | head -1 | jq '.usage.completion_tokens')
            echo "  Request $((i+1)): ${ELAPSED}s, ${TOKENS} tokens ✓"
            SUCCESS=$((SUCCESS + 1))
            TOTAL_TIME=$(echo "$TOTAL_TIME + $ELAPSED" | bc)
        else
            echo "  Request $((i+1)): FAILED ✗"
            FAIL=$((FAIL + 1))
        fi
    done

    echo ""
    echo "Results: $SUCCESS passed, $FAIL failed"
    if [ $SUCCESS -gt 0 ]; then
        AVG=$(echo "scale=3; $TOTAL_TIME / $SUCCESS" | bc)
        echo "Average latency: ${AVG}s"
    fi
}

cmd_throughput() {
    detect_model
    mkdir -p "$OUTPUT_DIR"
    local result_file="${OUTPUT_DIR}/throughput_${TIMESTAMP}.csv"

    echo "=== Throughput Benchmark ==="
    echo "Testing concurrency levels: 1, 2, 4, 8, 16, 32, 64"
    echo "Results: $result_file"
    echo ""

    echo "concurrency,requests,total_time_s,req_per_sec,avg_latency_s,p99_latency_s" > "$result_file"

    for CONCURRENCY in 1 2 4 8 16 32 64; do
        echo -n "  Concurrency $CONCURRENCY: "
        NUM_REQUESTS=$((CONCURRENCY * 5))
        LATENCIES=()

        START=$(date +%s%N)

        for i in $(seq 1 $NUM_REQUESTS); do
            (
                RESULT=$(send_request "Tell me a fun fact about the number $i" 50 2>/dev/null)
                LAT=$(echo "$RESULT" | tail -1)
                echo "$LAT" >> "${OUTPUT_DIR}/.lat_${CONCURRENCY}_${i}"
            ) &

            # Maintain concurrency level
            while [ $(jobs -r | wc -l) -ge $CONCURRENCY ]; do
                sleep 0.1
            done
        done
        wait

        END=$(date +%s%N)
        TOTAL=$(echo "scale=3; ($END - $START) / 1000000000" | bc)
        RPS=$(echo "scale=2; $NUM_REQUESTS / $TOTAL" | bc)

        # Collect latencies
        ALL_LATS=$(cat ${OUTPUT_DIR}/.lat_${CONCURRENCY}_* 2>/dev/null | sort -n)
        AVG_LAT=$(echo "$ALL_LATS" | awk '{s+=$1} END {printf "%.3f", s/NR}')
        P99_LAT=$(echo "$ALL_LATS" | awk 'BEGIN{n=0} {a[n++]=$1} END{printf "%.3f", a[int(n*0.99)]}')

        echo "${RPS} req/s, avg ${AVG_LAT}s, p99 ${P99_LAT}s"
        echo "${CONCURRENCY},${NUM_REQUESTS},${TOTAL},${RPS},${AVG_LAT},${P99_LAT}" >> "$result_file"

        # Cleanup temp files
        rm -f ${OUTPUT_DIR}/.lat_${CONCURRENCY}_*
    done

    echo ""
    echo "Results saved to: $result_file"
}

cmd_latency() {
    detect_model
    mkdir -p "$OUTPUT_DIR"

    echo "=== Latency Benchmark ==="
    echo "Sending 50 sequential requests..."
    echo ""

    LATENCIES=()
    for i in $(seq 1 50); do
        LAT=$(send_request "What is $i times $i?" 30 2>/dev/null | tail -1)
        LATENCIES+=("$LAT")
        printf "\r  Request %d/50: %ss" "$i" "$LAT"
    done
    echo ""

    # Calculate percentiles
    SORTED=$(printf '%s\n' "${LATENCIES[@]}" | sort -n)
    COUNT=${#LATENCIES[@]}
    P50=$(echo "$SORTED" | awk "NR==$(( (COUNT * 50 + 99) / 100 )){print}")
    P95=$(echo "$SORTED" | awk "NR==$(( (COUNT * 95 + 99) / 100 )){print}")
    P99=$(echo "$SORTED" | awk "NR==$(( (COUNT * 99 + 99) / 100 )){print}")
    MIN=$(echo "$SORTED" | head -1)
    MAX=$(echo "$SORTED" | tail -1)
    AVG=$(printf '%s\n' "${LATENCIES[@]}" | awk '{s+=$1} END {printf "%.3f", s/NR}')

    echo ""
    echo "Results:"
    echo "  Min:  ${MIN}s"
    echo "  P50:  ${P50}s"
    echo "  P95:  ${P95}s"
    echo "  P99:  ${P99}s"
    echo "  Max:  ${MAX}s"
    echo "  Avg:  ${AVG}s"
}

# Main
case "${1:-}" in
    quick)      cmd_quick ;;
    throughput) cmd_throughput ;;
    latency)    cmd_latency ;;
    *)          usage ;;
esac
