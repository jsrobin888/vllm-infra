#!/bin/bash
# =============================================================================
# GPU Health Check Script
# Validates GPU health across multiple dimensions.
# Exit code 0 = all healthy, non-zero = issues found.
# =============================================================================
set -euo pipefail

ERRORS=0
WARNINGS=0

echo "============================================="
echo " GPU Health Check Report"
echo " Host:  $(hostname)"
echo " Time:  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================="

# --- Check nvidia-smi availability ---
if ! command -v nvidia-smi &> /dev/null; then
    echo "[FATAL] nvidia-smi not found"
    exit 1
fi

# --- Check driver loaded ---
if ! nvidia-smi > /dev/null 2>&1; then
    echo "[FATAL] NVIDIA driver not responding"
    exit 1
fi

DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
GPU_COUNT=$(nvidia-smi --query-gpu=count --format=csv,noheader | head -1)
echo "[INFO] Driver: ${DRIVER_VERSION}"
echo "[INFO] GPU Count: ${GPU_COUNT}"
echo ""

# --- Per-GPU checks ---
for GPU_ID in $(seq 0 $((GPU_COUNT - 1))); do
    echo "--- GPU ${GPU_ID} ---"

    # Get GPU info
    GPU_NAME=$(nvidia-smi -i "$GPU_ID" --query-gpu=name --format=csv,noheader)
    GPU_TEMP=$(nvidia-smi -i "$GPU_ID" --query-gpu=temperature.gpu --format=csv,noheader)
    GPU_POWER=$(nvidia-smi -i "$GPU_ID" --query-gpu=power.draw --format=csv,noheader | tr -d ' W')
    GPU_MEM_USED=$(nvidia-smi -i "$GPU_ID" --query-gpu=memory.used --format=csv,noheader | tr -d ' MiB')
    GPU_MEM_TOTAL=$(nvidia-smi -i "$GPU_ID" --query-gpu=memory.total --format=csv,noheader | tr -d ' MiB')
    GPU_UTIL=$(nvidia-smi -i "$GPU_ID" --query-gpu=utilization.gpu --format=csv,noheader | tr -d ' %')
    GPU_ECC_SBE=$(nvidia-smi -i "$GPU_ID" --query-gpu=ecc.errors.corrected.aggregate.total --format=csv,noheader 2>/dev/null || echo "N/A")
    GPU_ECC_DBE=$(nvidia-smi -i "$GPU_ID" --query-gpu=ecc.errors.uncorrected.aggregate.total --format=csv,noheader 2>/dev/null || echo "N/A")
    GPU_PCIE_GEN=$(nvidia-smi -i "$GPU_ID" --query-gpu=pcie.link.gen.current --format=csv,noheader 2>/dev/null || echo "N/A")
    GPU_PCIE_WIDTH=$(nvidia-smi -i "$GPU_ID" --query-gpu=pcie.link.width.current --format=csv,noheader 2>/dev/null || echo "N/A")

    echo "  Name: ${GPU_NAME}"
    echo "  Temp: ${GPU_TEMP}°C"
    echo "  Power: ${GPU_POWER}W"
    echo "  Memory: ${GPU_MEM_USED}/${GPU_MEM_TOTAL} MiB"
    echo "  Utilization: ${GPU_UTIL}%"
    echo "  PCIe: Gen${GPU_PCIE_GEN} x${GPU_PCIE_WIDTH}"
    echo "  ECC SBE: ${GPU_ECC_SBE}, DBE: ${GPU_ECC_DBE}"

    # Temperature check
    if [[ "$GPU_TEMP" -gt 92 ]]; then
        echo "  [ERROR] Temperature CRITICAL: ${GPU_TEMP}°C > 92°C"
        ((ERRORS++))
    elif [[ "$GPU_TEMP" -gt 85 ]]; then
        echo "  [WARN] Temperature HIGH: ${GPU_TEMP}°C > 85°C"
        ((WARNINGS++))
    else
        echo "  [OK] Temperature normal"
    fi

    # ECC double-bit errors (uncorrectable)
    if [[ "$GPU_ECC_DBE" != "N/A" ]] && [[ "$GPU_ECC_DBE" -gt 0 ]]; then
        echo "  [ERROR] Uncorrectable ECC errors detected: ${GPU_ECC_DBE}"
        ((ERRORS++))
    fi

    # ECC single-bit errors (correctable but concerning if high)
    if [[ "$GPU_ECC_SBE" != "N/A" ]] && [[ "$GPU_ECC_SBE" -gt 100 ]]; then
        echo "  [WARN] High correctable ECC errors: ${GPU_ECC_SBE}"
        ((WARNINGS++))
    fi

    # PCIe link width check (A100/H100 should be x16)
    if [[ "$GPU_PCIE_WIDTH" != "N/A" ]] && [[ "$GPU_PCIE_WIDTH" -lt 16 ]]; then
        echo "  [WARN] PCIe width degraded: x${GPU_PCIE_WIDTH} (expected x16)"
        ((WARNINGS++))
    fi

    echo ""
done

# --- NVLink check (if available) ---
echo "--- NVLink Status ---"
if nvidia-smi nvlink --status > /dev/null 2>&1; then
    NVLINK_INACTIVE=$(nvidia-smi nvlink --status 2>/dev/null | grep -c "inactive" || echo "0")
    if [[ "$NVLINK_INACTIVE" -gt 0 ]]; then
        echo "[WARN] ${NVLINK_INACTIVE} inactive NVLink(s) detected"
        ((WARNINGS++))
    else
        echo "[OK] All NVLinks active"
    fi
else
    echo "[INFO] NVLink not available on this system"
fi

# --- Persistence mode check ---
echo ""
echo "--- Persistence Mode ---"
PERSIST=$(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader | head -1)
if [[ "$PERSIST" == "Enabled" ]]; then
    echo "[OK] Persistence mode enabled"
else
    echo "[WARN] Persistence mode disabled"
    ((WARNINGS++))
fi

# --- Summary ---
echo ""
echo "============================================="
echo " Summary"
echo "   Errors:   ${ERRORS}"
echo "   Warnings: ${WARNINGS}"
echo "============================================="

if [[ "$ERRORS" -gt 0 ]]; then
    echo "[RESULT] UNHEALTHY — ${ERRORS} error(s) found"
    exit 1
elif [[ "$WARNINGS" -gt 0 ]]; then
    echo "[RESULT] DEGRADED — ${WARNINGS} warning(s) found"
    exit 0  # Still exit 0 for warnings
else
    echo "[RESULT] HEALTHY — All checks passed"
    exit 0
fi
