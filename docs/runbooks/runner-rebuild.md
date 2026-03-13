# =============================================================================
# Runbook: Runner Rebuild from Scratch
# Phase 56: Incident Response — Stage 167
# =============================================================================

## When to Use

- GPU runner suffered catastrophic failure (OS corruption, disk failure)
- Fresh hardware being added to the fleet
- Runner needs to be reimaged after security incident
- Major OS/driver upgrade requiring clean install

---

## Prerequisites

- Fresh Ubuntu 22.04 LTS installed on the server
- Network connectivity (management + data VLANs)
- SSH access from control plane with deploy user's key
- Control plane has this repository cloned and configured

---

## Step-by-Step Rebuild

### Phase 1: OS Bootstrap (5 minutes)

```bash
# From the control plane, bootstrap the new runner
# This creates deploy user, hardens SSH, configures UFW
scripts/bootstrap/bootstrap-ubuntu.sh <runner_ip> root
```

### Phase 2: Update Inventory

Edit `ansible/inventory/hosts.yml` to add/update the runner entry:

```yaml
gpu_runners:
  hosts:
    gpu-runner-new:
      ansible_host: <runner_ip>
      gpu_type: a100
      gpu_count: 4
      models_to_serve:
        - name: "llama3-8b"
          model_path: "meta-llama/Meta-Llama-3-8B-Instruct"
          tp_size: 1
          gpu_ids: "0"
          port: 8000
```

### Phase 3: Full Provisioning (30-45 minutes)

```bash
# Run the full GPU runner provisioning playbook
ansible-playbook ansible/playbooks/gpu-runner-full.yml \
  --limit gpu-runner-new \
  --ask-vault-pass
```

This playbook runs these roles in order:
1. **base_system** — packages, users, kernel hardening, security
2. **nvidia_driver** — NVIDIA driver 550.90.07 + CUDA 12.4
3. **gpu_config** — power limits, ECC, compute mode, health checks
4. **docker_engine** — Docker CE 27.1.1 with NVIDIA runtime config
5. **nvidia_container_toolkit** — Container GPU support + CDI
6. **nfs_client** — Mount models from NFS storage
7. **monitoring_agents** — Node exporter + DCGM exporter + Promtail

**⚠️ Note:** A reboot is required after NVIDIA driver installation. The playbook handles this automatically.

### Phase 4: Deploy vLLM (5-10 minutes)

```bash
# Deploy vLLM containers
ansible-playbook ansible/playbooks/deploy-vllm.yml \
  --limit gpu-runner-new \
  --ask-vault-pass
```

### Phase 5: Validation (5 minutes)

```bash
# Run smoke tests against the new runner
tests/smoke/test-vllm-endpoint.sh http://<runner_ip>:8000

# Check GPU health
ssh deploy@<runner_ip> "nvidia-smi"

# Check all containers running
ssh deploy@<runner_ip> "docker ps"

# Check NFS mount
ssh deploy@<runner_ip> "ls /mnt/models/"
```

### Phase 6: Add to Load Balancer

```bash
# Update HAProxy to include the new runner
# Edit configs/haproxy/haproxy.cfg — add server line to appropriate backend

# Or use Ansible to redeploy HAProxy
ansible-playbook ansible/playbooks/monitoring-stack.yml \
  --tags haproxy \
  --ask-vault-pass
```

### Phase 7: Monitor

Watch the runner for 30 minutes:
- Grafana GPU dashboard — temperatures, utilization
- Prometheus alerts — no new alerts
- vLLM logs — `docker logs -f vllm-<model>`

---

## Automated Rebuild

For fastest recovery, use the DR manager:

```bash
scripts/disaster-recovery/dr-manager.sh rebuild <runner_hostname>
```

This runs phases 3-5 automatically.

---

## Timing Estimates

| Phase | Duration | Notes |
|-------|----------|-------|
| OS Install | 15-20 min | Manual or PXE |
| Bootstrap | 5 min | SSH + base config |
| Full provisioning | 30-45 min | Driver install + reboot |
| vLLM deploy | 5-10 min | Image pull + start |
| Validation | 5 min | Smoke tests |
| **Total** | **~60-85 min** | From bare metal to serving |

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| NVIDIA driver install fails | Check kernel version matches, ensure nouveau is blacklisted |
| NFS mount fails | Check network to storage, verify exports |
| Docker GPU test fails | Verify nvidia-container-toolkit, check `nvidia-ctk runtime configure` |
| vLLM OOM | Reduce TP size or model size for available GPU memory |
| Slow model loading | Check NFS throughput: `dd if=/mnt/models/test of=/dev/null bs=1M count=1000` |
