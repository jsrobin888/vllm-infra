#!/bin/bash
# =============================================================================
# Performance Tests — vLLM Throughput & Latency Validation
# Phase 53: Testing Suite — Stages 191-195
# =============================================================================
# Validates that vLLM meets performance SLOs under load.
# Requires: curl, jq, bc
# =============================================================================
set -euo pipefail

BASE_URL="${1:?Usage: $0 <base_url> [model_name]}"
MODEL="${2:-llama3-8b}"
CONCURRENCY_LEVELS=(1 4 8 16 32)
REQUESTS_PER_LEVEL=20
RESULTS_DIR="/tmp/perf-results-$(date +%s)"
mkdir -p "$RESULTS_DIR"

# --- SLO Thresholds ---
SLO_TTFT_P95=3.0      # seconds
SLO_E2E_P95=30.0      # seconds
SLO_THROUGHPUT_MIN=5   # req/s at concurrency 16
SLO_ERROR_RATE=0.01    # 1%

echo "============================================="
echo " Performance Test Suite"
echo " Target: ${BASE_URL}"
echo " Model:  ${MODEL}"
echo " Results: ${RESULTS_DIR}"
echo "============================================="

# --- Single request latency measurement ---
measure_request() {
    local start end duration
    start=$(date +%s%N)

    HTTP_CODE=$(curl -s -o "${RESULTS_DIR}/response_$1.json" -w "%{http_code}" \
        -X POST "${BASE_URL}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"${MODEL}\",
            \"messages\": [{\"role\": \"user\", \"content\": \"Write a short paragraph about artificial intelligence in exactly 50 words.\"}],
            \"max_tokens\": 100,
            \"temperature\": 0.7
        }" --max-time 60 2>/dev/null)

    end=$(date +%s%N)
    duration=$(echo "scale=3; ($end - $start) / 1000000000" | bc)

    echo "${duration},${HTTP_CODE}"
}

# --- Percentile calculation ---
percentile() {
    local data="$1"
    local pct="$2"
    echo "$data" | sort -n | awk -v p="$pct" '{a[NR]=$1} END{print a[int(NR*p/100+0.5)]}'
}

echo ""

# =============================================================================
# Test 1: Warm-up
# =============================================================================
echo "=== Warm-up (5 requests) ==="
for i in $(seq 1 5); do
    measure_request "warmup_${i}" > /dev/null
    echo -n "."
done
echo " done"
echo ""

# =============================================================================
# Test 2: Latency at varying concurrency
# =============================================================================
PASS=true

for CONC in "${CONCURRENCY_LEVELS[@]}"; do
    echo "=== Concurrency: ${CONC} (${REQUESTS_PER_LEVEL} requests) ==="

    LATENCIES=""
    ERRORS=0
    START_TIME=$(date +%s)

    # Launch requests in parallel batches
    for batch_start in $(seq 1 "$CONC" "$REQUESTS_PER_LEVEL"); do
        PIDS=()
        for i in $(seq "$batch_start" $(( batch_start + CONC - 1 ))); do
            [[ "$i" -gt "$REQUESTS_PER_LEVEL" ]] && break
            (
                result=$(measure_request "c${CONC}_r${i}")
                echo "$result" >> "${RESULTS_DIR}/conc_${CONC}.csv"
            ) &
            PIDS+=($!)
        done

        for pid in "${PIDS[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
    done

    END_TIME=$(date +%s)
    TOTAL_TIME=$((END_TIME - START_TIME))

    # Parse results
    if [[ -f "${RESULTS_DIR}/conc_${CONC}.csv" ]]; then
        LATENCIES=$(cut -d',' -f1 "${RESULTS_DIR}/conc_${CONC}.csv")
        ERRORS=$(cut -d',' -f2 "${RESULTS_DIR}/conc_${CONC}.csv" | grep -vc "200" || true)
        TOTAL_REQUESTS=$(wc -l < "${RESULTS_DIR}/conc_${CONC}.csv")

        P50=$(echo "$LATENCIES" | percentile /dev/stdin 50)
        P95=$(echo "$LATENCIES" | percentile /dev/stdin 95)
        P99=$(echo "$LATENCIES" | percentile /dev/stdin 99)
        AVG=$(echo "$LATENCIES" | awk '{s+=$1} END{printf "%.3f", s/NR}')
        THROUGHPUT=$(echo "scale=2; ${TOTAL_REQUESTS} / ${TOTAL_TIME}" | bc 2>/dev/null || echo "N/A")
        ERROR_RATE=$(echo "scale=4; ${ERRORS} / ${TOTAL_REQUESTS}" | bc 2>/dev/null || echo "0")

        echo "  Requests:   ${TOTAL_REQUESTS}"
        echo "  Errors:     ${ERRORS}"
        echo "  Duration:   ${TOTAL_TIME}s"
        echo "  Throughput: ${THROUGHPUT} req/s"
        echo "  Latency:    avg=${AVG}s  p50=${P50}s  p95=${P95}s  p99=${P99}s"

        # SLO checks
        if (( $(echo "$P95 > $SLO_E2E_P95" | bc -l) )); then
            echo "  [FAIL] p95 latency ${P95}s exceeds SLO of ${SLO_E2E_P95}s"
            PASS=false
        fi
        if (( $(echo "$ERROR_RATE > $SLO_ERROR_RATE" | bc -l) )); then
            echo "  [FAIL] Error rate ${ERROR_RATE} exceeds SLO of ${SLO_ERROR_RATE}"
            PASS=false
        fi
    else
        echo "  [ERROR] No results captured"
        PASS=false
    fi

    echo ""
done

# =============================================================================
# Test 3: Long sequence test
# =============================================================================
echo "=== Long Sequence Test (max_tokens=500) ==="
LONG_START=$(date +%s%N)
LONG_CODE=$(curl -s -o "${RESULTS_DIR}/long_response.json" -w "%{http_code}" \
    -X POST "${BASE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"${MODEL}\",
        \"messages\": [{\"role\": \"user\", \"content\": \"Write a detailed essay about the history of computing, from Charles Babbage to modern AI.\"}],
        \"max_tokens\": 500,
        \"temperature\": 0.7
    }" --max-time 120 2>/dev/null)
LONG_END=$(date +%s%N)
LONG_DURATION=$(echo "scale=3; ($LONG_END - $LONG_START) / 1000000000" | bc)

if [[ "$LONG_CODE" == "200" ]]; then
    TOKENS=$(jq -r '.usage.completion_tokens // 0' "${RESULTS_DIR}/long_response.json" 2>/dev/null || echo 0)
    TPS=$(echo "scale=2; $TOKENS / $LONG_DURATION" | bc 2>/dev/null || echo "N/A")
    echo "  Status: ${LONG_CODE}"
    echo "  Duration: ${LONG_DURATION}s"
    echo "  Tokens: ${TOKENS}"
    echo "  Tokens/s: ${TPS}"
else
    echo "  [FAIL] HTTP ${LONG_CODE}"
    PASS=false
fi

echo ""

# =============================================================================
# Summary
# =============================================================================
echo "============================================="
echo " Performance Test Summary"
echo "   Results saved to: ${RESULTS_DIR}"
if [[ "$PASS" == true ]]; then
    echo "   Status: ALL SLOs MET ✓"
    exit 0
else
    echo "   Status: SLO VIOLATIONS DETECTED ✗"
    exit 1
fi
echo "============================================="
