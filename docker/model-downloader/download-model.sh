#!/bin/bash
# =============================================================================
# Model Download Script for Docker Container
# Downloads a model from HuggingFace Hub to /models/<model_name>
# =============================================================================
set -euo pipefail

MODEL_ID="${MODEL_ID:?MODEL_ID environment variable required}"
OUTPUT_DIR="${OUTPUT_DIR:-/models}"
HF_TOKEN="${HF_TOKEN:-}"
REVISION="${REVISION:-main}"

MODEL_NAME=$(echo "$MODEL_ID" | tr '/' '--')
TARGET_DIR="${OUTPUT_DIR}/${MODEL_NAME}"

echo "============================================="
echo " Model Downloader"
echo " Model:    ${MODEL_ID}"
echo " Revision: ${REVISION}"
echo " Target:   ${TARGET_DIR}"
echo " Time:     $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================="

# --- Check if model already exists ---
if [[ -f "${TARGET_DIR}/.download_complete" ]]; then
    EXISTING_REV=$(cat "${TARGET_DIR}/.revision" 2>/dev/null || echo "unknown")
    if [[ "$EXISTING_REV" == "$REVISION" ]]; then
        echo "[INFO] Model already downloaded at revision ${REVISION}. Skipping."
        exit 0
    else
        echo "[INFO] Model exists at revision ${EXISTING_REV}, updating to ${REVISION}."
    fi
fi

# --- Build huggingface-cli command ---
HF_CMD="huggingface-cli download ${MODEL_ID}"
HF_CMD+=" --local-dir ${TARGET_DIR}"
HF_CMD+=" --revision ${REVISION}"
HF_CMD+=" --local-dir-use-symlinks False"

if [[ -n "$HF_TOKEN" ]]; then
    HF_CMD+=" --token ${HF_TOKEN}"
    echo "[INFO] Using HuggingFace token for authenticated download."
fi

# --- Download ---
echo "[DOWNLOAD] Starting download..."
START_TIME=$(date +%s)

eval "$HF_CMD"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
echo "[DOWNLOAD] Completed in ${DURATION} seconds."

# --- Record metadata ---
echo "$REVISION" > "${TARGET_DIR}/.revision"
date -u '+%Y-%m-%dT%H:%M:%SZ' > "${TARGET_DIR}/.download_timestamp"
touch "${TARGET_DIR}/.download_complete"

# --- Generate checksums ---
echo "[CHECKSUM] Generating SHA256 checksums..."
CHECKSUM_FILE="${TARGET_DIR}/SHA256SUMS"
find "${TARGET_DIR}" -type f \
    ! -name "SHA256SUMS" \
    ! -name ".download_*" \
    ! -name ".revision" \
    -exec sha256sum {} \; > "${CHECKSUM_FILE}"

TOTAL_SIZE=$(du -sh "${TARGET_DIR}" | cut -f1)
FILE_COUNT=$(find "${TARGET_DIR}" -type f | wc -l)

echo ""
echo "============================================="
echo " Download Complete"
echo " Size:   ${TOTAL_SIZE}"
echo " Files:  ${FILE_COUNT}"
echo " Time:   ${DURATION}s"
echo "============================================="

# --- Generate metadata JSON ---
/usr/local/bin/generate-metadata.sh \
    "${MODEL_ID}" "${TARGET_DIR}" "${REVISION}" "${DURATION}" "${TOTAL_SIZE}"
