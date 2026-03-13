#!/bin/bash
# =============================================================================
# Disaster Recovery — Phase 33 (Stages 210–213)
# Full runner rebuild from scratch
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ANSIBLE_DIR="${INFRA_ROOT}/ansible"
INVENTORY="${ANSIBLE_DIR}/inventory/hosts.yml"

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  rebuild <hostname>     Full rebuild of a GPU runner from scratch
  nfs-failover           Switch NFS mount to secondary server
  nfs-failback           Switch NFS mount back to primary server
  backup-configs         Backup all configurations to git
  verify-fleet           Verify entire fleet health

Examples:
  $(basename "$0") rebuild gpu-runner-01
  $(basename "$0") nfs-failover
  $(basename "$0") verify-fleet
EOF
}

cmd_rebuild() {
    local host="${1:?ERROR: Specify hostname to rebuild}"
    echo "=== FULL REBUILD: $host ==="
    echo "This will:"
    echo "  1. Remove from load balancer"
    echo "  2. Re-provision OS, drivers, Docker, NFS"
    echo "  3. Deploy vLLM containers"
    echo "  4. Verify health"
    echo "  5. Re-add to load balancer"
    echo ""
    read -p "Continue with full rebuild of $host? (y/N): " confirm
    [ "$confirm" = "y" ] || exit 0

    START=$(date +%s)

    echo ""
    echo ">>> Step 1: Full provisioning..."
    cd "$ANSIBLE_DIR"
    ansible-playbook -i "$INVENTORY" playbooks/gpu-runner-full.yml --limit "$host"

    echo ""
    echo ">>> Step 2: Deploy vLLM..."
    ansible-playbook -i "$INVENTORY" playbooks/deploy-vllm.yml --limit "$host"

    END=$(date +%s)
    DURATION=$((END - START))
    echo ""
    echo "=== REBUILD COMPLETE ==="
    echo "Host:     $host"
    echo "Duration: $((DURATION / 60))m $((DURATION % 60))s"
}

cmd_nfs_failover() {
    echo "=== NFS Failover to Secondary ==="
    cd "$ANSIBLE_DIR"
    ansible gpu_runners -i "$INVENTORY" -m shell -a '
        umount -l /mnt/models 2>/dev/null || true
        sed -i "s|{{ nfs_server_ip }}|{{ nfs_server_secondary_ip }}|g" /etc/fstab
        mount /mnt/models
        mountpoint -q /mnt/models && echo "Failover SUCCESS" || echo "Failover FAILED"
    ' --become
}

cmd_nfs_failback() {
    echo "=== NFS Failback to Primary ==="
    cd "$ANSIBLE_DIR"
    ansible gpu_runners -i "$INVENTORY" -m shell -a '
        umount -l /mnt/models 2>/dev/null || true
        sed -i "s|{{ nfs_server_secondary_ip }}|{{ nfs_server_ip }}|g" /etc/fstab
        mount /mnt/models
        mountpoint -q /mnt/models && echo "Failback SUCCESS" || echo "Failback FAILED"
    ' --become
}

cmd_verify_fleet() {
    echo "=== Fleet Health Verification ==="
    echo ""
    cd "$ANSIBLE_DIR"

    echo "--- GPU Runners ---"
    ansible gpu_runners -i "$INVENTORY" -m script -a '/opt/vllm/scripts/gpu-health-check.sh' --become 2>/dev/null
    echo ""

    echo "--- NFS Mounts ---"
    ansible gpu_runners -i "$INVENTORY" -m shell -a '
        mountpoint -q /mnt/models && echo "$(hostname): NFS OK" || echo "$(hostname): NFS FAILED"
    ' 2>/dev/null
    echo ""

    echo "--- vLLM Containers ---"
    ansible gpu_runners -i "$INVENTORY" -m shell -a '
        docker ps --filter "name=vllm" --format "$(hostname): {{.Names}} {{.Status}}"
    ' 2>/dev/null
}

# Main
case "${1:-}" in
    rebuild)        shift; cmd_rebuild "$@" ;;
    nfs-failover)   cmd_nfs_failover ;;
    nfs-failback)   cmd_nfs_failback ;;
    backup-configs) echo "Backing up configs to git..." && cd "$INFRA_ROOT" && git add -A && git commit -m "Config backup $(date -u +%Y-%m-%dT%H:%M:%SZ)" ;;
    verify-fleet)   cmd_verify_fleet ;;
    *)              usage ;;
esac
