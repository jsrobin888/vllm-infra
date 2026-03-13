#!/bin/bash
# =============================================================================
# Smoke Test — Stage 190: vLLM Endpoint Validation
# =============================================================================
set -euo pipefail

VLLM_URL="${1:-http://localhost:8000}"
ERRORS=0

echo "=== vLLM Smoke Test ==="
echo "Target: $VLLM_URL"
echo ""

# Test 1: Health endpoint
echo -n "Test 1 — Health endpoint: "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${VLLM_URL}/health")
if [ "$HTTP_CODE" = "200" ]; then
    echo "PASS (HTTP $HTTP_CODE)"
else
    echo "FAIL (HTTP $HTTP_CODE)"
    ERRORS=$((ERRORS + 1))
fi

# Test 2: Models endpoint
echo -n "Test 2 — Models endpoint: "
MODELS=$(curl -s --max-time 10 "${VLLM_URL}/v1/models")
MODEL_COUNT=$(echo "$MODELS" | jq '.data | length' 2>/dev/null || echo "0")
if [ "$MODEL_COUNT" -gt 0 ]; then
    MODEL_NAME=$(echo "$MODELS" | jq -r '.data[0].id')
    echo "PASS ($MODEL_COUNT model(s): $MODEL_NAME)"
else
    echo "FAIL (no models found)"
    ERRORS=$((ERRORS + 1))
fi

# Test 3: Chat completion
echo -n "Test 3 — Chat completion: "
RESPONSE=$(curl -s --max-time 60 \
    -X POST "${VLLM_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"${MODEL_NAME:-test}\",
        \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in exactly one word.\"}],
        \"max_tokens\": 10,
        \"temperature\": 0
    }")

if echo "$RESPONSE" | jq -e '.choices[0].message.content' &>/dev/null; then
    CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content')
    TOKENS=$(echo "$RESPONSE" | jq '.usage.total_tokens')
    echo "PASS (response: '$CONTENT', tokens: $TOKENS)"
else
    echo "FAIL (no valid response)"
    echo "  Response: $RESPONSE"
    ERRORS=$((ERRORS + 1))
fi

# Test 4: Completions endpoint
echo -n "Test 4 — Completions endpoint: "
RESPONSE=$(curl -s --max-time 60 \
    -X POST "${VLLM_URL}/v1/completions" \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"${MODEL_NAME:-test}\",
        \"prompt\": \"The capital of France is\",
        \"max_tokens\": 10,
        \"temperature\": 0
    }")

if echo "$RESPONSE" | jq -e '.choices[0].text' &>/dev/null; then
    echo "PASS"
else
    echo "FAIL"
    ERRORS=$((ERRORS + 1))
fi

# Test 5: Streaming
echo -n "Test 5 — Streaming: "
STREAM_RESULT=$(curl -s --max-time 60 \
    -X POST "${VLLM_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"${MODEL_NAME:-test}\",
        \"messages\": [{\"role\": \"user\", \"content\": \"Count to 3.\"}],
        \"max_tokens\": 20,
        \"stream\": true
    }" | head -5)

if echo "$STREAM_RESULT" | grep -q "data:"; then
    echo "PASS (streaming chunks received)"
else
    echo "FAIL (no stream data)"
    ERRORS=$((ERRORS + 1))
fi

# Summary
echo ""
echo "========================"
if [ $ERRORS -eq 0 ]; then
    echo "ALL TESTS PASSED ✓"
    exit 0
else
    echo "FAILED: $ERRORS test(s) ✗"
    exit 1
fi
