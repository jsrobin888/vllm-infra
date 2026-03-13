# =============================================================================
# Quick Start Guide
# vLLM Production Infrastructure
# =============================================================================

## Prerequisites

- **Control plane**: Ubuntu 22.04 or macOS with Ansible 2.17+ installed
- **Target servers**: Ubuntu 22.04 LTS with SSH access
- **Network**: Management VLAN connectivity between control plane and all nodes
- **Credentials**: Root or sudo access on all target servers

---

## Step 1: Clone and Configure

```bash
git clone <repo-url> vllm-infra
cd vllm-infra

# Copy and edit inventory
cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
vim ansible/inventory/hosts.yml   # Set your IPs, GPU configs, model assignments

# Copy and edit vault secrets
cp ansible/group_vars/all/vault.yml.example ansible/group_vars/all/vault.yml
ansible-vault encrypt ansible/group_vars/all/vault.yml
```

---

## Step 2: Bootstrap Servers

For each new server (first-time setup only):

```bash
# Creates deploy user, hardens SSH, sets up UFW
scripts/bootstrap/bootstrap-ubuntu.sh <server_ip> root
```

---

## Step 3: Deploy Storage Server

```bash
ansible-playbook ansible/playbooks/storage-server.yml --ask-vault-pass
```

---

## Step 4: Download Models

```bash
# Download a model to the NFS storage
ansible-playbook ansible/playbooks/model-download.yml \
  -e "model_id=meta-llama/Meta-Llama-3-8B-Instruct" \
  --ask-vault-pass
```

---

## Step 5: Provision GPU Runners

```bash
# Full provisioning (driver, Docker, NFS, monitoring)
# Takes 30-45 minutes per runner (includes driver install + reboot)
ansible-playbook ansible/playbooks/gpu-runner-full.yml --ask-vault-pass
```

---

## Step 6: Deploy vLLM

```bash
ansible-playbook ansible/playbooks/deploy-vllm.yml --ask-vault-pass
```

---

## Step 7: Deploy Monitoring

```bash
ansible-playbook ansible/playbooks/monitoring-stack.yml --ask-vault-pass
```

---

## Step 8: Deploy Load Balancer

```bash
ansible-playbook ansible/playbooks/load-balancer.yml --ask-vault-pass
```

---

## Step 9: Verify

```bash
# Smoke test each runner
tests/smoke/test-vllm-endpoint.sh http://<runner_ip>:8000

# Full integration test
tests/integration/test-full-stack.sh

# Fleet health check
ansible-playbook ansible/playbooks/fleet-health-check.yml
```

---

## Day-2 Operations

| Task | Command |
|------|---------|
| Rolling vLLM update | `ansible-playbook ansible/playbooks/rolling-update-vllm.yml -e "vllm_version=0.8.4"` |
| Download new model | `ansible-playbook ansible/playbooks/model-download.yml -e "model_id=..."` |
| Add new GPU runner | `ansible-playbook ansible/playbooks/scale-add-runner.yml -e "target_host=gpu-runner-04"` |
| Remove GPU runner | `ansible-playbook ansible/playbooks/scale-remove-runner.yml -e "target_host=gpu-runner-02"` |
| Security audit | `ansible-playbook ansible/playbooks/security-audit.yml` |
| Fleet health check | `ansible-playbook ansible/playbooks/fleet-health-check.yml` |
| GPU power profile | `scripts/gpu/power-manager.sh profile balanced` |
| Run benchmarks | `scripts/benchmarks/vllm-benchmark.sh http://<runner>:8000 llama3-8b` |
| DR: NFS failover | `scripts/disaster-recovery/dr-manager.sh nfs-failover` |
| DR: Rebuild runner | `scripts/disaster-recovery/dr-manager.sh rebuild <hostname>` |

---

## Grafana Dashboards

After deploying the monitoring stack, access Grafana at `http://<monitoring_ip>:3000`:

1. **GPU Fleet Overview** — Temperature, power, memory, utilization for all GPUs
2. **vLLM Inference Performance** — Latency, throughput, queue depth, KV cache
3. **Model Serving Dashboard** — Per-model health, requests, TTFT
4. **Infrastructure Health** — CPU, memory, disk, network, NFS, Docker
5. **Capacity Planning** — Trends, projections, power consumption

---

## Incident Response

See runbooks in `docs/runbooks/`:
- [vLLM Down](docs/runbooks/vllm-down.md)
- [GPU Temperature High](docs/runbooks/gpu-temperature-high.md)
- [NFS Mount Stale](docs/runbooks/nfs-mount-stale.md)
- [Runner Rebuild](docs/runbooks/runner-rebuild.md)
