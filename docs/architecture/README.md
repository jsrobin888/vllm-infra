# =============================================================================
# Architecture Documentation
# vLLM Production Infrastructure
# =============================================================================

## High-Level Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                           CLIENTS / API CONSUMERS                        │
└──────────────────────────┬───────────────────────────────────────────────┘
                           │ HTTPS (TLS 1.3)
                           ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                     LOAD BALANCER TIER (HAProxy x2)                      │
│  ┌─────────────┐  ┌─────────────┐                                       │
│  │  haproxy-01  │  │  haproxy-02  │  (Active/Passive with keepalived)    │
│  │  VIP: x.x.x │  │  Standby     │                                      │
│  └──────┬───────┘  └──────┬──────┘                                       │
│         │ Rate Limiting, API Key Auth, Health-Check Routing               │
└─────────┼──────────────────┼─────────────────────────────────────────────┘
          │                  │
          ▼                  ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                        GPU RUNNER TIER (Stateless)                        │
│                                                                          │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐       │
│  │  gpu-runner-01    │  │  gpu-runner-02    │  │  gpu-runner-03    │      │
│  │  4× A100-80GB     │  │  4× A100-80GB     │  │  8× H100-80GB     │    │
│  │                   │  │                   │  │                    │     │
│  │  ┌─────────────┐  │  │  ┌─────────────┐  │  │  ┌─────────────┐  │    │
│  │  │ vLLM: llama │  │  │  │ vLLM: llama │  │  │  │ vLLM: llama │  │    │
│  │  │  3-8b (TP1) │  │  │  │  3-8b (TP1) │  │  │  │  3-70b(TP4) │  │    │
│  │  └─────────────┘  │  │  └─────────────┘  │  │  └─────────────┘  │    │
│  │  ┌─────────────┐  │  │  ┌─────────────┐  │  │  ┌─────────────┐  │    │
│  │  │ vLLM:mixtral│  │  │  │ vLLM:mixtral│  │  │  │ vLLM: code  │  │    │
│  │  │  8x7b (TP2) │  │  │  │  8x7b (TP2) │  │  │  │  llama(TP4) │  │    │
│  │  └─────────────┘  │  │  └─────────────┘  │  │  └─────────────┘  │    │
│  │                   │  │                   │  │                    │     │
│  │  NFS: /mnt/models │  │  NFS: /mnt/models │  │  NFS: /mnt/models │    │
│  │  (read-only)      │  │  (read-only)      │  │  (read-only)      │    │
│  └──────────┬────────┘  └──────────┬────────┘  └──────────┬────────┘    │
└─────────────┼───────────────────────┼───────────────────────┼────────────┘
              │                       │                       │
              └───────────────────────┼───────────────────────┘
                                      │ NFS v4.1 (read-only)
                                      ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                      STORAGE TIER (NFS + ZFS)                            │
│                                                                          │
│  ┌─────────────────────────┐    ┌─────────────────────────┐             │
│  │  storage-primary         │    │  storage-secondary       │            │
│  │  ZFS raidz2 (6× NVMe)   │    │  ZFS raidz2 (6× NVMe)   │           │
│  │  /data/models/           │◄──►│  /data/models/           │           │
│  │  NFS export (rw for mgmt)│    │  rsync replication       │           │
│  │  Snapshots: 14d retention│    │  Standby for failover    │           │
│  └─────────────────────────┘    └─────────────────────────┘             │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│                       OBSERVABILITY TIER                                  │
│                                                                          │
│  ┌────────────┐  ┌────────────┐  ┌────────┐  ┌──────────────┐          │
│  │ Prometheus  │  │  Grafana   │  │  Loki  │  │ Alertmanager │          │
│  │ (metrics)   │  │ (dashboards│  │ (logs) │  │ (→ Slack/PD) │          │
│  │             │  │  5 boards) │  │        │  │              │           │
│  └─────┬──────┘  └────────────┘  └────┬───┘  └──────────────┘          │
│        │ scrapes                       │ receives                        │
│        ├─ node_exporter (all hosts)    ├─ promtail (all hosts)          │
│        ├─ dcgm_exporter (GPU runners)  └─ Docker log driver             │
│        ├─ vLLM /metrics endpoints                                        │
│        └─ Docker daemon metrics                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Network Architecture

### VLANs

| VLAN | Name | Subnet | Purpose |
|------|------|--------|---------|
| 10 | Management | 10.0.1.0/24 | SSH, Ansible, monitoring |
| 20 | Data / Storage | 10.0.2.0/24 | NFS traffic, model loading |
| 30 | Service / API | 10.0.3.0/24 | Client-facing API traffic |

### Firewall Rules (UFW)

| Source | Destination | Port | Protocol | Purpose |
|--------|------------|------|----------|---------|
| Control Plane | All | 22 | TCP | SSH management |
| GPU Runners | Storage | 2049 | TCP | NFS |
| Monitoring | All | 9100 | TCP | node_exporter |
| Monitoring | GPU Runners | 9400 | TCP | DCGM exporter |
| Monitoring | GPU Runners | 8000-8100 | TCP | vLLM metrics |
| Load Balancers | GPU Runners | 8000-8100 | TCP | API traffic |
| Clients | Load Balancers | 443 | TCP | HTTPS API |

---

## Data Flow

### Model Loading Flow

```
1. Operator runs: ansible-playbook playbooks/model-download.yml
2. Download playbook → storage-primary:/data/models/<model_name>/
3. Checksums generated → SHA256SUMS
4. Metadata generated → /data/metadata/<model>.json
5. Catalog updated → /data/models/catalog.json
6. NFS exports model directory (read-only to data VLAN)
7. GPU runners mount via NFS: /mnt/models → /data/models
8. vLLM container reads model from /models (bind mount from /mnt/models)
9. Model loaded into GPU VRAM at container startup
```

### Request Flow

```
1. Client → HAProxy (TLS termination, API key validation)
2. HAProxy → selects backend based on model name in URL path
3. HAProxy → health-checked GPU runner (leastconn algorithm)
4. GPU Runner → vLLM container processes request
5. vLLM → GPU inference (tensor parallelism if TP > 1)
6. Response streams back: vLLM → HAProxy → Client
```

### Monitoring Flow

```
1. Prometheus scrapes targets every 15s:
   - node_exporter:9100 (system metrics)
   - dcgm_exporter:9400 (GPU metrics)
   - vLLM:8000/metrics (inference metrics)
2. Alert rules evaluate continuously
3. Alertmanager routes alerts → Slack (#gpu-alerts, #vllm-alerts) + PagerDuty
4. Grafana queries Prometheus for dashboards
5. Promtail ships logs → Loki → Grafana (log exploration)
```

---

## Deployment Strategy

### Rolling Update Process

```
For each GPU runner (one at a time):
  1. Drain from HAProxy (set weight 0, wait for active connections)
  2. Pull new vLLM Docker image
  3. Stop existing containers (docker compose down)
  4. Start new containers (docker compose up -d)
  5. Wait for health check (up to 5 minutes for large models)
  6. Run smoke test (chat completion request)
  7. Re-enable in HAProxy (set weight back)
  8. Wait 60s stability window
  9. Proceed to next runner
```

### Rollback Strategy

```
1. Version marker file: /opt/vllm/.current_version
2. Previous image tagged: vllm/vllm-openai:v<previous>
3. Docker image kept locally (not pruned for 7 days)
4. Rollback: deploy-manager.sh rollback <version>
   - Reverts docker-compose.yml to previous version
   - Pulls previous image (usually cached)
   - Restarts containers
```

---

## Security Architecture

### Network Security
- All inter-node traffic on private VLANs
- TLS 1.3 for client-facing traffic (HAProxy termination)
- NFS exports restricted by subnet
- UFW on all nodes (deny by default)

### Host Security
- SSH: key-only, no root login, port 22 (management VLAN only)
- fail2ban: SSH brute-force protection
- AppArmor: enabled on all nodes
- auditd: file access, privilege escalation, command logging
- unattended-upgrades: security patches (kernel/nvidia excluded)
- Login banner: legal warning

### Container Security
- Docker: no-new-privileges by default
- Docker: user namespace mapping where possible
- vLLM containers run as non-root (uid 1000)
- NFS mounted read-only in containers
- Trivy scan in CI/CD pipeline
- Image pinned to exact version (no :latest)

### Secrets Management
- Ansible Vault for sensitive variables
- HuggingFace tokens, API keys, credentials encrypted
- Vault file not committed to git (.gitignore)
- Optional: HashiCorp Vault integration for dynamic secrets

---

## Capacity Planning

### GPU Memory Requirements

| Model | Parameters | Format | Min GPU Memory | Recommended TP |
|-------|-----------|--------|---------------|----------------|
| Llama-3-8B | 8B | FP16 | 16 GB | 1 (A100-80GB) |
| Llama-3-70B | 70B | FP16 | 140 GB | 2-4 (A100-80GB) |
| Mixtral-8x7B | 47B | FP16 | 94 GB | 2 (A100-80GB) |
| Llama-3-405B | 405B | FP8 | 405 GB | 8 (H100-80GB) |
| Code-Llama-34B | 34B | FP16 | 68 GB | 1-2 (A100-80GB) |

### Storage Requirements

| Model | Disk Size | Notes |
|-------|----------|-------|
| Llama-3-8B | ~15 GB | safetensors format |
| Llama-3-70B | ~130 GB | safetensors format |
| Mixtral-8x7B | ~87 GB | safetensors format |
| **Total (5 models)** | **~500 GB** | Plus 50% headroom |

### Network Bandwidth

- Model loading: ~1-5 GB/s needed from NFS (NVMe-backed ZFS)
- API traffic: ~100 Mbps per runner at peak (mostly text)
- Monitoring: ~5 Mbps aggregate (metrics + logs)
