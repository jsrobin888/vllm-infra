#!/bin/bash
# =============================================================================
# Generate model metadata JSON
# =============================================================================
set -euo pipefail

MODEL_ID="$1"
TARGET_DIR="$2"
REVISION="${3:-main}"
DURATION="${4:-0}"
TOTAL_SIZE="${5:-unknown}"

MODEL_NAME=$(echo "$MODEL_ID" | tr '/' '--')
METADATA_FILE="/metadata/${MODEL_NAME}.json"

# --- Detect model format ---
FORMAT="unknown"
if ls "${TARGET_DIR}"/*.safetensors > /dev/null 2>&1; then
    FORMAT="safetensors"
elif ls "${TARGET_DIR}"/*.bin > /dev/null 2>&1; then
    FORMAT="pytorch_bin"
elif ls "${TARGET_DIR}"/*.gguf > /dev/null 2>&1; then
    FORMAT="gguf"
fi

# --- Count shards ---
SHARD_COUNT=0
if [[ "$FORMAT" == "safetensors" ]]; then
    SHARD_COUNT=$(ls "${TARGET_DIR}"/*.safetensors 2>/dev/null | wc -l)
elif [[ "$FORMAT" == "pytorch_bin" ]]; then
    SHARD_COUNT=$(ls "${TARGET_DIR}"/*.bin 2>/dev/null | wc -l)
fi

# --- Read config if present ---
MAX_SEQ_LEN="null"
if [[ -f "${TARGET_DIR}/config.json" ]]; then
    MAX_SEQ_LEN=$(jq -r '.max_position_embeddings // .max_seq_len // .n_positions // "null"' \
        "${TARGET_DIR}/config.json" 2>/dev/null || echo "null")
fi

# --- Write metadata ---
cat > "${METADATA_FILE}" <<EOF
{
    "model_id": "${MODEL_ID}",
    "model_name": "${MODEL_NAME}",
    "revision": "${REVISION}",
    "format": "${FORMAT}",
    "shard_count": ${SHARD_COUNT},
    "total_size": "${TOTAL_SIZE}",
    "max_sequence_length": ${MAX_SEQ_LEN},
    "download_duration_seconds": ${DURATION},
    "download_timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "storage_path": "${TARGET_DIR}",
    "checksum_file": "${TARGET_DIR}/SHA256SUMS"
}
EOF

echo "[METADATA] Written to ${METADATA_FILE}"
