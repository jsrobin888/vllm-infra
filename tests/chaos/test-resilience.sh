#!/bin/bash
# =============================================================================
# Chaos Tests — Resilience & Recovery Validation
# Phase 53: Testing Suite — Stages 196-200
# =============================================================================
# Validates system resilience by injecting failures and measuring recovery.
# WARNING: Only run against staging/test environments!
# =============================================================================
set -euo pipefail

TARGET="${1:?Usage: $0 <runner_hostname_or_ip>}"
BASE_URL="${2:-http://${TARGET}:8000}"
SSH_USER="${SSH_USER:-deploy}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo "============================================="
echo " Chaos Test Suite"
echo " Target: ${TARGET}"
echo " API:    ${BASE_URL}"
echo -e " ${RED}⚠  DESTRUCTIVE TESTS — STAGING ONLY${NC}"
echo "============================================="
echo ""

# --- Confirmation ---
read -p "This will disrupt services on ${TARGET}. Continue? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

# --- Helpers ---
ssh_cmd() { ssh -o StrictHostKeyChecking=no "${SSH_USER}@${TARGET}" "$@"; }

wait_for_health() {
    local url="$1"
    local timeout="${2:-300}"
    local start=$(date +%s)

    while true; do
        if curl -s -f "${url}/health" > /dev/null 2>&1; then
            local elapsed=$(( $(date +%s) - start ))
            echo "  Recovered in ${elapsed}s"
            return 0
        fi
        local elapsed=$(( $(date +%s) - start ))
        if [[ $elapsed -gt $timeout ]]; then
            echo "  [FAIL] Did not recover within ${timeout}s"
            return 1
        fi
        sleep 5
    done
}

PASS=0
FAIL=0

run_chaos() {
    local name="$1"
    echo ""
    echo "=== Chaos: ${name} ==="
}

# =============================================================================
# Test 1: Kill vLLM Container → Docker Restart Policy Recovery
# =============================================================================
run_chaos "Kill vLLM container (restart policy test)"

echo "  Killing vLLM container..."
CONTAINER=$(ssh_cmd "docker ps --filter 'name=vllm' -q | head -1")
if [[ -z "$CONTAINER" ]]; then
    echo "  [SKIP] No vLLM container found"
else
    ssh_cmd "docker kill ${CONTAINER}"
    echo "  Container killed. Waiting for Docker restart policy..."

    if wait_for_health "$BASE_URL" 180; then
        echo -e "  ${GREEN}[PASS]${NC} Container auto-recovered"
        ((PASS++))
    else
        echo -e "  ${RED}[FAIL]${NC} Container did not auto-recover"
        ((FAIL++))
    fi
fi

# =============================================================================
# Test 2: Fill /tmp disk space → Graceful degradation
# =============================================================================
run_chaos "Fill /tmp disk (resource exhaustion)"

echo "  Creating 1GB temp file..."
ssh_cmd "dd if=/dev/zero of=/tmp/chaos-test-fill bs=1M count=1024 2>/dev/null || true"
sleep 5

echo "  Checking vLLM still responds..."
if curl -s -f "${BASE_URL}/health" > /dev/null 2>&1; then
    echo -e "  ${GREEN}[PASS]${NC} vLLM healthy despite /tmp pressure"
    ((PASS++))
else
    echo -e "  ${RED}[FAIL]${NC} vLLM unhealthy under disk pressure"
    ((FAIL++))
fi

echo "  Cleaning up..."
ssh_cmd "rm -f /tmp/chaos-test-fill"

# =============================================================================
# Test 3: Network partition to NFS (simulate stale mount)
# =============================================================================
run_chaos "Block NFS traffic (network partition)"

echo "  Blocking NFS port 2049..."
ssh_cmd "sudo iptables -A OUTPUT -p tcp --dport 2049 -j DROP" || true
sleep 10

echo "  Checking if vLLM handles NFS disruption..."
# vLLM should still serve cached/loaded models even if NFS is temporarily unavailable
if curl -s -f --max-time 10 "${BASE_URL}/health" > /dev/null 2>&1; then
    echo -e "  ${GREEN}[PASS]${NC} vLLM survived NFS disruption (model in GPU memory)"
    ((PASS++))
else
    echo -e "  ${YELLOW}[WARN]${NC} vLLM affected by NFS disruption"
    ((FAIL++))
fi

echo "  Restoring NFS connectivity..."
ssh_cmd "sudo iptables -D OUTPUT -p tcp --dport 2049 -j DROP" || true
sleep 5

# =============================================================================
# Test 4: OOM-like memory pressure
# =============================================================================
run_chaos "Memory pressure (stress test)"

echo "  Allocating 4GB of memory..."
ssh_cmd "stress-ng --vm 1 --vm-bytes 4G --timeout 15s 2>/dev/null &" || \
    echo "  [SKIP] stress-ng not installed"

sleep 10
echo "  Checking vLLM under memory pressure..."
if curl -s -f --max-time 30 "${BASE_URL}/health" > /dev/null 2>&1; then
    echo -e "  ${GREEN}[PASS]${NC} vLLM healthy under memory pressure"
    ((PASS++))
else
    echo -e "  ${RED}[FAIL]${NC} vLLM unhealthy under memory pressure"
    ((FAIL++))
fi

sleep 10  # Let stress-ng finish

# =============================================================================
# Test 5: Restart Docker daemon → Full service recovery
# =============================================================================
run_chaos "Docker daemon restart (full restart test)"

echo "  Restarting Docker daemon..."
ssh_cmd "sudo systemctl restart docker"
echo "  Docker restarting. Waiting for all services to recover..."

if wait_for_health "$BASE_URL" 300; then
    echo -e "  ${GREEN}[PASS]${NC} Full recovery after Docker restart"
    ((PASS++))

    # Verify inference still works
    INFER_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "${BASE_URL}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d '{"model":"llama3-8b","messages":[{"role":"user","content":"Hello"}],"max_tokens":5}' \
        --max-time 60 2>/dev/null)

    if [[ "$INFER_CODE" == "200" ]]; then
        echo -e "  ${GREEN}[PASS]${NC} Inference working after recovery"
        ((PASS++))
    else
        echo -e "  ${RED}[FAIL]${NC} Inference broken after recovery (HTTP ${INFER_CODE})"
        ((FAIL++))
    fi
else
    echo -e "  ${RED}[FAIL]${NC} Did not recover after Docker restart"
    ((FAIL++))
fi

# =============================================================================
# Test 6: GPU reset (if safe to do)
# =============================================================================
run_chaos "GPU reset (nvidia-smi --gpu-reset)"

echo "  Checking if GPU reset is safe (no other GPU processes)..."
GPU_PROCS=$(ssh_cmd "nvidia-smi --query-compute-apps=pid --format=csv,noheader | wc -l" || echo "0")

if [[ "$GPU_PROCS" -gt 0 ]]; then
    echo "  [SKIP] GPU has active processes (${GPU_PROCS}). Reset would kill workloads."
    echo "  This test should be run on an idle runner."
else
    echo "  Resetting GPU 0..."
    ssh_cmd "sudo nvidia-smi --gpu-reset -i 0" || true
    sleep 5

    if ssh_cmd "nvidia-smi > /dev/null 2>&1"; then
        echo -e "  ${GREEN}[PASS]${NC} GPU recovered from reset"
        ((PASS++))
    else
        echo -e "  ${RED}[FAIL]${NC} GPU not responding after reset"
        ((FAIL++))
    fi
fi

# =============================================================================
# Summary
# =============================================================================
TOTAL=$((PASS + FAIL))
echo ""
echo "============================================="
echo " Chaos Test Results"
echo "   Total:  ${TOTAL}"
echo -e "   ${GREEN}Passed: ${PASS}${NC}"
echo -e "   ${RED}Failed: ${FAIL}${NC}"
echo "============================================="

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
