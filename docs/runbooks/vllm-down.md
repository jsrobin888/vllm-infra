# =============================================================================
# Runbook: vLLM Service Down
# Phase 56: Incident Response — Stage 165
# =============================================================================

## Alert: VLLMDown

**Severity:** Critical
**Category:** vLLM
**SLO Impact:** Availability

---

## Symptoms

- `up{job="vllm"} == 0` for >2 minutes
- HTTP 502/503 from load balancer
- No response on `/health` endpoint

---

## Immediate Actions (First 5 minutes)

### 1. Identify affected instance

```bash
# Check which runner is down
scripts/deploy/deploy-manager.sh status
```

### 2. Check container status

```bash
ssh gpu-runner-XX
docker ps -a --filter "name=vllm"
docker logs --tail 100 vllm-<model-name>
```

### 3. Common root causes & fixes

#### A. Container crashed (OOM / CUDA error)

```bash
# Check for OOM
dmesg | grep -i "oom\|killed"
docker inspect vllm-<name> | jq '.[0].State'

# Fix: Restart container
docker compose -f /opt/vllm/compose/docker-compose.yml restart

# If OOM, reduce memory:
# Edit /opt/vllm/compose/.env → reduce gpu_memory_utilization to 0.85
```

#### B. GPU fallen off bus

```bash
nvidia-smi
# If "Unable to determine the device handle" or missing GPUs:

# Option 1: Reset GPU
nvidia-smi -r -i <gpu_id>

# Option 2: Full reboot required
sudo reboot
```

#### C. NFS mount stale

```bash
mountpoint -q /mnt/models
ls /mnt/models/  # If hangs, mount is stale

# Fix
sudo umount -l /mnt/models
sudo mount /mnt/models
```

#### D. Model file corrupted

```bash
# Verify checksums
cd /mnt/models/<provider>/<model>/v1
sha256sum -c .checksums.sha256
```

### 4. Verify recovery

```bash
# Health check
curl http://localhost:8000/health

# Smoke test
scripts/benchmarks/vllm-benchmark.sh quick
```

---

## Escalation

| Time | Action |
|------|--------|
| 0–5 min | On-call engineer: diagnose & restart |
| 5–15 min | If not resolved: check GPU hardware, NFS |
| 15–30 min | If persistent: failover to healthy runners, page senior engineer |
| 30+ min | Hardware issue: open vendor support ticket |

---

## Prevention

- Enable `--enable-sleep-mode` for idle GPU memory release
- Set `gpu-memory-utilization` to 0.85 (not 0.95) for headroom
- Monitor ECC errors proactively
- Weekly GPU health check cron

---

## Related Runbooks

- [GPU Temperature High](./gpu-temperature-high.md)
- [NFS Mount Stale](./nfs-mount-stale.md)
- [Full Runner Rebuild](./runner-rebuild.md)
