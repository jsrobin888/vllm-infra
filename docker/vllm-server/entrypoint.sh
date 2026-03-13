#!/bin/bash
# =============================================================================
# vLLM Server Entrypoint
# Performs pre-flight checks before starting vLLM
# =============================================================================
set -euo pipefail

echo "============================================="
echo " vLLM Production Server — Entrypoint"
echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================="

# --- Pre-flight: Check GPU availability ---
echo "[PRE-FLIGHT] Checking GPU availability..."
if ! nvidia-smi > /dev/null 2>&1; then
    echo "[FATAL] No NVIDIA GPU detected. Exiting."
    exit 1
fi

GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
echo "[PRE-FLIGHT] Found ${GPU_COUNT} GPU(s):"
nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader

# --- Pre-flight: Check model path ---
MODEL_PATH="${MODEL:-}"
if [[ -n "$MODEL_PATH" ]] && [[ "$MODEL_PATH" == /* ]]; then
    echo "[PRE-FLIGHT] Checking local model path: ${MODEL_PATH}"
    if [[ ! -d "$MODEL_PATH" ]] && [[ ! -f "$MODEL_PATH" ]]; then
        echo "[WARN] Model path not found locally: ${MODEL_PATH}"
        echo "[WARN] vLLM will attempt to download from HuggingFace Hub"
    else
        MODEL_SIZE=$(du -sh "$MODEL_PATH" 2>/dev/null | cut -f1 || echo "unknown")
        echo "[PRE-FLIGHT] Model found: ${MODEL_PATH} (${MODEL_SIZE})"
    fi
fi

# --- Pre-flight: Check NCCL (multi-GPU) ---
TP_SIZE="${TENSOR_PARALLEL_SIZE:-1}"
if [[ "$TP_SIZE" -gt 1 ]]; then
    echo "[PRE-FLIGHT] Tensor Parallelism: ${TP_SIZE} GPUs"
    echo "[PRE-FLIGHT] NCCL_DEBUG=${NCCL_DEBUG:-WARN}"
    echo "[PRE-FLIGHT] NCCL_P2P_DISABLE=${NCCL_P2P_DISABLE:-not set}"
    echo "[PRE-FLIGHT] NCCL_IB_DISABLE=${NCCL_IB_DISABLE:-not set}"
fi

# --- Pre-flight: Memory check ---
echo "[PRE-FLIGHT] System memory:"
free -h | head -2

echo "[PRE-FLIGHT] GPU memory:"
nvidia-smi --query-gpu=index,memory.total,memory.free --format=csv,noheader

# --- Log configuration ---
echo ""
echo "[CONFIG] Starting vLLM with arguments:"
echo "  $@"
echo "============================================="

# --- Execute vLLM ---
exec python -m vllm.entrypoints.openai.api_server "$@"
