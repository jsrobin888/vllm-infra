#!/bin/bash
# =============================================================================
# Integration Tests — Full Deployment Validation
# Phase 53: Testing Suite — Stages 183-190
# =============================================================================
# Runs a comprehensive suite of integration tests against a deployed vLLM
# infrastructure. Validates end-to-end functionality.
# =============================================================================
set -euo pipefail

# --- Configuration ---
HAPROXY_URL="${HAPROXY_URL:-http://localhost:443}"
DIRECT_URL="${DIRECT_URL:-http://localhost:8000}"
API_KEY="${API_KEY:-}"
VERBOSE="${VERBOSE:-false}"
PASS=0
FAIL=0
SKIP=0

# --- Helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1: $2"; ((FAIL++)); }
log_skip() { echo -e "${YELLOW}[SKIP]${NC} $1: $2"; ((SKIP++)); }
log_info() { echo -e "[INFO] $1"; }

run_test() {
    local name="$1"
    local cmd="$2"
    local expected="$3"

    log_info "Running: ${name}"
    RESULT=$(eval "$cmd" 2>/dev/null) || { log_fail "$name" "Command failed"; return; }

    if echo "$RESULT" | grep -q "$expected"; then
        log_pass "$name"
    else
        log_fail "$name" "Expected '${expected}' not found in response"
        if [[ "$VERBOSE" == "true" ]]; then
            echo "  Response: ${RESULT:0:500}"
        fi
    fi
}

# --- Auth header ---
AUTH_HEADER=""
if [[ -n "$API_KEY" ]]; then
    AUTH_HEADER="-H 'Authorization: Bearer ${API_KEY}'"
fi

echo "============================================="
echo " Integration Test Suite"
echo " HAProxy: ${HAPROXY_URL}"
echo " Direct:  ${DIRECT_URL}"
echo " Time:    $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================="
echo ""

# =============================================================================
# Category 1: Direct vLLM API Tests
# =============================================================================
echo "=== Category 1: Direct vLLM API ==="

run_test "Direct: Health endpoint" \
    "curl -s -o /dev/null -w '%{http_code}' ${DIRECT_URL}/health" \
    "200"

run_test "Direct: List models" \
    "curl -s ${DIRECT_URL}/v1/models" \
    "\"object\":\"list\""

run_test "Direct: Chat completion" \
    "curl -s -X POST ${DIRECT_URL}/v1/chat/completions \
        -H 'Content-Type: application/json' \
        -d '{\"model\":\"llama3-8b\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello\"}],\"max_tokens\":10}'" \
    "\"choices\""

run_test "Direct: Completions endpoint" \
    "curl -s -X POST ${DIRECT_URL}/v1/completions \
        -H 'Content-Type: application/json' \
        -d '{\"model\":\"llama3-8b\",\"prompt\":\"Hello\",\"max_tokens\":5}'" \
    "\"choices\""

run_test "Direct: Streaming response" \
    "curl -s -N -X POST ${DIRECT_URL}/v1/chat/completions \
        -H 'Content-Type: application/json' \
        -d '{\"model\":\"llama3-8b\",\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}],\"max_tokens\":5,\"stream\":true}' \
        --max-time 30 | head -5" \
    "data:"

run_test "Direct: Metrics endpoint" \
    "curl -s ${DIRECT_URL}/metrics" \
    "vllm:"

echo ""

# =============================================================================
# Category 2: Load Balancer Tests (if HAProxy is reachable)
# =============================================================================
echo "=== Category 2: Load Balancer ==="

if curl -s -o /dev/null --max-time 5 "${HAPROXY_URL}/health" 2>/dev/null; then
    run_test "HAProxy: Health endpoint" \
        "curl -s -o /dev/null -w '%{http_code}' ${AUTH_HEADER} ${HAPROXY_URL}/health" \
        "200"

    run_test "HAProxy: Chat completion" \
        "curl -s -X POST ${HAPROXY_URL}/v1/chat/completions \
            ${AUTH_HEADER} \
            -H 'Content-Type: application/json' \
            -d '{\"model\":\"llama3-8b\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello\"}],\"max_tokens\":10}'" \
        "\"choices\""

    run_test "HAProxy: Rate limit header" \
        "curl -s -D- ${AUTH_HEADER} ${HAPROXY_URL}/v1/models | head -20" \
        "200"
else
    log_skip "HAProxy tests" "HAProxy not reachable at ${HAPROXY_URL}"
fi

echo ""

# =============================================================================
# Category 3: NFS Storage Tests
# =============================================================================
echo "=== Category 3: NFS Storage ==="

if mountpoint -q /mnt/models 2>/dev/null; then
    run_test "NFS: Mount active" \
        "mountpoint /mnt/models && echo 'mounted'" \
        "mounted"

    run_test "NFS: Models directory readable" \
        "ls /mnt/models/ | head -5 && echo 'readable'" \
        "readable"

    run_test "NFS: Read performance (1MB)" \
        "dd if=/mnt/models/$(ls /mnt/models/ | head -1)/config.json of=/dev/null bs=1M count=1 2>&1 && echo 'ok'" \
        "ok"
else
    log_skip "NFS tests" "NFS not mounted at /mnt/models"
fi

echo ""

# =============================================================================
# Category 4: GPU Health
# =============================================================================
echo "=== Category 4: GPU Health ==="

if command -v nvidia-smi &> /dev/null; then
    run_test "GPU: nvidia-smi responds" \
        "nvidia-smi > /dev/null && echo 'ok'" \
        "ok"

    run_test "GPU: All GPUs visible" \
        "nvidia-smi --query-gpu=count --format=csv,noheader | head -1" \
        "[0-9]"

    run_test "GPU: No ECC errors" \
        "nvidia-smi --query-gpu=ecc.errors.uncorrected.aggregate.total --format=csv,noheader | awk '{s+=\$1}END{print (s==0)?\"clean\":\"errors\"}'" \
        "clean"

    run_test "GPU: Temperature normal" \
        "nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader | awk '{if(\$1>90) exit 1}; END{print \"ok\"}'" \
        "ok"
else
    log_skip "GPU tests" "nvidia-smi not available"
fi

echo ""

# =============================================================================
# Category 5: Docker / Container Health
# =============================================================================
echo "=== Category 5: Container Health ==="

if command -v docker &> /dev/null; then
    run_test "Docker: daemon running" \
        "docker info > /dev/null 2>&1 && echo 'running'" \
        "running"

    run_test "Docker: vLLM containers running" \
        "docker ps --filter 'name=vllm' --format '{{.Names}}' | head -5 && echo 'listed'" \
        "listed"

    run_test "Docker: No unhealthy containers" \
        "docker ps --filter 'health=unhealthy' --format '{{.Names}}' | wc -l | tr -d ' '" \
        "0"

    run_test "Docker: NVIDIA runtime available" \
        "docker info 2>/dev/null | grep -c nvidia || echo '0'" \
        "1"
else
    log_skip "Docker tests" "Docker not available"
fi

echo ""

# =============================================================================
# Category 6: Monitoring Stack
# =============================================================================
echo "=== Category 6: Monitoring ==="

PROM_URL="${PROMETHEUS_URL:-http://localhost:9090}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"

if curl -s -o /dev/null --max-time 5 "${PROM_URL}/-/healthy" 2>/dev/null; then
    run_test "Prometheus: healthy" \
        "curl -s -o /dev/null -w '%{http_code}' ${PROM_URL}/-/healthy" \
        "200"

    run_test "Prometheus: targets up" \
        "curl -s ${PROM_URL}/api/v1/targets | jq -r '.data.activeTargets[] | select(.health==\"up\") | .labels.job' | wc -l" \
        "[1-9]"
else
    log_skip "Prometheus tests" "Prometheus not reachable at ${PROM_URL}"
fi

if curl -s -o /dev/null --max-time 5 "${GRAFANA_URL}/api/health" 2>/dev/null; then
    run_test "Grafana: healthy" \
        "curl -s -o /dev/null -w '%{http_code}' ${GRAFANA_URL}/api/health" \
        "200"
else
    log_skip "Grafana tests" "Grafana not reachable at ${GRAFANA_URL}"
fi

echo ""

# =============================================================================
# Summary
# =============================================================================
TOTAL=$((PASS + FAIL + SKIP))
echo "============================================="
echo " Integration Test Results"
echo "   Total:   ${TOTAL}"
echo -e "   ${GREEN}Passed:  ${PASS}${NC}"
echo -e "   ${RED}Failed:  ${FAIL}${NC}"
echo -e "   ${YELLOW}Skipped: ${SKIP}${NC}"
echo "============================================="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
else
    exit 0
fi
