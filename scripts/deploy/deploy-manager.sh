#!/bin/bash
# =============================================================================
# Deploy Helper — Phase 30: Deployment Operations (Stages 194–198)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ANSIBLE_DIR="${INFRA_ROOT}/ansible"
INVENTORY="${ANSIBLE_DIR}/inventory/hosts.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  deploy          Deploy vLLM to all runners (rolling)
  deploy-one      Deploy to specific runner
  rollback        Rollback to previous image tag
  update-image    Update vLLM image across fleet
  status          Show fleet deployment status
  drain           Drain a runner (remove from LB)
  enable          Re-enable a runner in LB
  restart         Restart vLLM containers on a runner

Examples:
  $(basename "$0") deploy
  $(basename "$0") deploy-one gpu-runner-01
  $(basename "$0") update-image v0.8.4
  $(basename "$0") rollback v0.8.3
  $(basename "$0") status
  $(basename "$0") drain gpu-runner-01
  $(basename "$0") restart gpu-runner-01
EOF
}

cmd_deploy() {
    echo -e "${GREEN}=== Rolling Deploy — All GPU Runners ===${NC}"
    cd "$ANSIBLE_DIR"
    ansible-playbook -i "$INVENTORY" playbooks/deploy-vllm.yml "$@"
}

cmd_deploy_one() {
    local host="${1:?ERROR: Specify hostname, e.g., gpu-runner-01}"
    shift
    echo -e "${GREEN}=== Deploy to $host ===${NC}"
    cd "$ANSIBLE_DIR"
    ansible-playbook -i "$INVENTORY" playbooks/deploy-vllm.yml --limit "$host" "$@"
}

cmd_update_image() {
    local tag="${1:?ERROR: Specify new image tag, e.g., v0.8.4}"
    echo -e "${YELLOW}=== Rolling Update to $tag ===${NC}"
    cd "$ANSIBLE_DIR"
    ansible-playbook -i "$INVENTORY" playbooks/rolling-update-vllm.yml \
        -e "new_vllm_image_tag=$tag"
}

cmd_rollback() {
    local tag="${1:?ERROR: Specify rollback image tag, e.g., v0.8.3}"
    echo -e "${RED}=== ROLLBACK to $tag ===${NC}"
    echo "This will update all runners to $tag"
    read -p "Continue? (y/N): " confirm
    if [ "$confirm" != "y" ]; then
        echo "Aborted."
        exit 0
    fi
    cd "$ANSIBLE_DIR"
    ansible-playbook -i "$INVENTORY" playbooks/rolling-update-vllm.yml \
        -e "new_vllm_image_tag=$tag"
}

cmd_status() {
    echo -e "${GREEN}=== Fleet Deployment Status ===${NC}"
    echo ""
    cd "$ANSIBLE_DIR"
    ansible gpu_runners -i "$INVENTORY" -m shell -a '
        echo "--- $(hostname) ---"
        echo "Docker containers:"
        docker ps --filter "name=vllm" --format "  {{.Names}}: {{.Status}} ({{.Image}})"
        echo "GPU status:"
        nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader | while read line; do echo "  GPU $line"; done
        echo "NFS mount: $(mountpoint -q /mnt/models && echo OK || echo FAILED)"
        echo ""
    ' 2>/dev/null
}

cmd_restart() {
    local host="${1:?ERROR: Specify hostname}"
    echo -e "${YELLOW}=== Restart vLLM on $host ===${NC}"
    cd "$ANSIBLE_DIR"
    ansible "$host" -i "$INVENTORY" -m shell -a '
        cd /opt/vllm/compose && docker compose restart
    ' --become
}

# Main
case "${1:-}" in
    deploy)       shift; cmd_deploy "$@" ;;
    deploy-one)   shift; cmd_deploy_one "$@" ;;
    update-image) shift; cmd_update_image "$@" ;;
    rollback)     shift; cmd_rollback "$@" ;;
    status)       cmd_status ;;
    restart)      shift; cmd_restart "$@" ;;
    *)            usage ;;
esac
