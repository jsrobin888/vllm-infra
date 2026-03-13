#!/bin/bash
# =============================================================================
# vLLM Server Health Check
# Returns 0 (healthy) if /health endpoint responds 200
# =============================================================================
set -euo pipefail

PORT="${VLLM_PORT:-8000}"
TIMEOUT="${HEALTH_TIMEOUT:-5}"

# Check if the vLLM health endpoint responds
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time "${TIMEOUT}" \
    "http://localhost:${PORT}/health" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "200" ]]; then
    exit 0
else
    echo "Health check failed: HTTP ${HTTP_CODE}"
    exit 1
fi
