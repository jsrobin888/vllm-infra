#!/bin/bash
# =============================================================================
# Fleet Inventory Reporter
# Phase 54: Operational Readiness — Stages 201-205
# =============================================================================
# Generates a comprehensive fleet inventory report.
# =============================================================================
set -euo pipefail

OUTPUT="${1:-/tmp/fleet-inventory-$(date +%Y%m%d).md}"

echo "# Fleet Inventory Report" > "$OUTPUT"
echo "" >> "$OUTPUT"
echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$OUTPUT"
echo "" >> "$OUTPUT"

# --- GPU Runners ---
echo "## GPU Runners" >> "$OUTPUT"
echo "" >> "$OUTPUT"
echo "| Host | IP | GPUs | GPU Type | Driver | CUDA | Docker | vLLM Containers |" >> "$OUTPUT"
echo "|------|----|----|----------|--------|------|--------|----------------|" >> "$OUTPUT"

for runner in $(ansible gpu_runners --list-hosts 2>/dev/null | tail -n +2 | tr -d ' '); do
    IP=$(ansible-inventory --host "$runner" 2>/dev/null | jq -r '.ansible_host // "N/A"')
    GPU_INFO=$(ssh -o ConnectTimeout=5 "deploy@${IP}" "nvidia-smi --query-gpu=count,name,driver_version --format=csv,noheader 2>/dev/null | head -1" 2>/dev/null || echo "N/A, N/A, N/A")
    DOCKER_VER=$(ssh -o ConnectTimeout=5 "deploy@${IP}" "docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+'" 2>/dev/null || echo "N/A")
    CONTAINERS=$(ssh -o ConnectTimeout=5 "deploy@${IP}" "docker ps --filter name=vllm -q 2>/dev/null | wc -l" 2>/dev/null || echo "N/A")

    IFS=',' read -r GPU_COUNT GPU_TYPE DRIVER <<< "$GPU_INFO"
    echo "| ${runner} | ${IP} | ${GPU_COUNT} | ${GPU_TYPE} | ${DRIVER} | - | ${DOCKER_VER} | ${CONTAINERS} |" >> "$OUTPUT"
done

echo "" >> "$OUTPUT"

# --- Storage Servers ---
echo "## Storage Servers" >> "$OUTPUT"
echo "" >> "$OUTPUT"
echo "| Host | IP | ZFS Pool | Capacity | Models | NFS Clients |" >> "$OUTPUT"
echo "|------|----|---------|---------:|--------|-------------|" >> "$OUTPUT"

for storage in $(ansible storage_servers --list-hosts 2>/dev/null | tail -n +2 | tr -d ' '); do
    IP=$(ansible-inventory --host "$storage" 2>/dev/null | jq -r '.ansible_host // "N/A"')
    POOL_INFO=$(ssh -o ConnectTimeout=5 "deploy@${IP}" "zpool list -H -o name,size,alloc,free 2>/dev/null | head -1" 2>/dev/null || echo "N/A")
    MODEL_COUNT=$(ssh -o ConnectTimeout=5 "deploy@${IP}" "ls -d /data/models/*/ 2>/dev/null | wc -l" 2>/dev/null || echo "N/A")
    NFS_CLIENTS=$(ssh -o ConnectTimeout=5 "deploy@${IP}" "ss -tn state established '( dport = :2049 )' 2>/dev/null | tail -n +2 | wc -l" 2>/dev/null || echo "N/A")

    echo "| ${storage} | ${IP} | ${POOL_INFO} | ${MODEL_COUNT} | ${NFS_CLIENTS} |" >> "$OUTPUT"
done

echo "" >> "$OUTPUT"

# --- Models Catalog ---
echo "## Models" >> "$OUTPUT"
echo "" >> "$OUTPUT"
echo "| Model | Size | Format | Runners Serving |" >> "$OUTPUT"
echo "|-------|------|--------|----------------|" >> "$OUTPUT"

STORAGE_IP=$(ansible-inventory --host "$(ansible storage_servers --list-hosts 2>/dev/null | tail -n +2 | head -1 | tr -d ' ')" 2>/dev/null | jq -r '.ansible_host // "N/A"')
if [[ "$STORAGE_IP" != "N/A" ]]; then
    ssh -o ConnectTimeout=5 "deploy@${STORAGE_IP}" "
        for dir in /data/models/*/; do
            name=\$(basename \"\$dir\")
            size=\$(du -sh \"\$dir\" 2>/dev/null | cut -f1)
            format='unknown'
            ls \"\$dir\"/*.safetensors >/dev/null 2>&1 && format='safetensors'
            ls \"\$dir\"/*.bin >/dev/null 2>&1 && format='pytorch'
            echo \"| \${name} | \${size} | \${format} | - |\"
        done
    " 2>/dev/null >> "$OUTPUT" || echo "| (unable to query) | - | - | - |" >> "$OUTPUT"
fi

echo "" >> "$OUTPUT"
echo "---" >> "$OUTPUT"
echo "Report complete." >> "$OUTPUT"

echo "Fleet inventory saved to: ${OUTPUT}"
cat "$OUTPUT"
