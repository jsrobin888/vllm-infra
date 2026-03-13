#!/bin/bash
# =============================================================================
# GPU Diagnostics — Deep Dive
# Collects comprehensive diagnostic data for troubleshooting.
# =============================================================================
set -euo pipefail

OUTPUT_DIR="${1:-/tmp/gpu-diagnostics}"
mkdir -p "$OUTPUT_DIR"

echo "Collecting GPU diagnostics to: ${OUTPUT_DIR}"

# --- nvidia-smi full output ---
nvidia-smi > "${OUTPUT_DIR}/nvidia-smi.txt" 2>&1
nvidia-smi -q > "${OUTPUT_DIR}/nvidia-smi-query.txt" 2>&1

# --- Topology ---
nvidia-smi topo -m > "${OUTPUT_DIR}/gpu-topology.txt" 2>&1 || echo "N/A" > "${OUTPUT_DIR}/gpu-topology.txt"

# --- NVLink ---
nvidia-smi nvlink --status > "${OUTPUT_DIR}/nvlink-status.txt" 2>&1 || echo "N/A" > "${OUTPUT_DIR}/nvlink-status.txt"

# --- Per-GPU details ---
nvidia-smi --query-gpu=index,name,driver_version,pci.bus_id,temperature.gpu,power.draw,power.limit,memory.total,memory.used,memory.free,utilization.gpu,utilization.memory,ecc.mode.current,ecc.errors.corrected.aggregate.total,ecc.errors.uncorrected.aggregate.total,pcie.link.gen.current,pcie.link.width.current,compute_mode,persistence_mode,clocks.gr,clocks.mem \
    --format=csv > "${OUTPUT_DIR}/gpu-details.csv" 2>&1

# --- PCIe info ---
lspci | grep -i nvidia > "${OUTPUT_DIR}/lspci-nvidia.txt" 2>&1 || echo "N/A"
lspci -vv -d 10de: > "${OUTPUT_DIR}/lspci-nvidia-verbose.txt" 2>&1 || echo "N/A"

# --- NUMA topology ---
if command -v numactl &> /dev/null; then
    numactl --hardware > "${OUTPUT_DIR}/numa-hardware.txt" 2>&1
fi

# --- Kernel modules ---
lsmod | grep -E "nvidia|nouveau" > "${OUTPUT_DIR}/kernel-modules.txt" 2>&1

# --- dmesg GPU errors ---
dmesg | grep -i -E "nvidia|gpu|nvrm|xid" > "${OUTPUT_DIR}/dmesg-gpu.txt" 2>&1 || echo "None found"

# --- System info ---
uname -a > "${OUTPUT_DIR}/system-info.txt"
cat /etc/os-release >> "${OUTPUT_DIR}/system-info.txt" 2>/dev/null
free -h >> "${OUTPUT_DIR}/system-info.txt"

echo "Diagnostics collected in: ${OUTPUT_DIR}"
ls -la "${OUTPUT_DIR}/"
