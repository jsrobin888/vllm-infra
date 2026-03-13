# =============================================================================
# Runbook: NFS Mount Stale / Unavailable
# Phase 56: Incident Response — Stage 166
# =============================================================================

## Alert: NFSMountStale / NFSMountLatencyHigh

**Severity:** Critical (stale) / Warning (latency > 100ms)
**Category:** Storage / Network

---

## Symptoms

- vLLM containers failing to start with "model not found"
- `df -h /mnt/models` hanging or returning "Stale file handle"
- Slow model loading times
- Prometheus alert `NFSMountStale` or `NFSMountLatencyHigh` firing

---

## Immediate Actions

### 1. Check NFS mount status on affected runner

```bash
# Check mount
mount | grep nfs
stat /mnt/models

# Test read access
ls -la /mnt/models/
time dd if=/mnt/models/test-file of=/dev/null bs=1M count=100

# Check for stale handle
cat /proc/mounts | grep nfs
```

### 2. If mount is stale — remount

```bash
# Lazy unmount then remount
sudo umount -l /mnt/models
sudo mount -a

# Verify
ls /mnt/models/
```

### 3. If mount fails — check NFS server

```bash
# From any node that can reach storage
showmount -e storage-primary.internal

# On the NFS server itself
systemctl status nfs-server
exportfs -v
zpool status data_pool
```

### 4. Check network path

```bash
# Ping NFS server
ping -c 5 storage-primary.internal

# Check NFS port
nc -zv storage-primary.internal 2049

# Check for packet loss
mtr -c 20 --report storage-primary.internal
```

---

## Root Causes

| Cause | Diagnosis | Fix |
|-------|-----------|-----|
| NFS server down | `systemctl status nfs-server` shows failed | Restart: `systemctl restart nfs-server` |
| Network partition | Ping fails, MTR shows loss | Check switches, cables, firewall rules |
| ZFS pool degraded | `zpool status` shows DEGRADED | Replace failed disk, `zpool resilver` |
| NFS threads exhausted | High NFS latency, server CPU normal | Increase threads in `/etc/nfs.conf` |
| Export config wrong | `exportfs -v` missing entry | Fix `/etc/exports`, run `exportfs -ra` |
| Firewall blocking | `nc -zv` fails, ping works | Open ports 2049, 111 in UFW |

---

## Recovery Steps

### Scenario A: NFS server restart needed

```bash
# On storage server
sudo systemctl restart nfs-server
sudo exportfs -ra

# On all GPU runners
ansible gpu_runners -m shell -a "umount -l /mnt/models; mount -a; ls /mnt/models/"
```

### Scenario B: Full NFS failover to secondary

```bash
# Use DR manager
scripts/disaster-recovery/dr-manager.sh nfs-failover

# Or manually on each runner
sudo sed -i 's/storage-primary.internal/storage-secondary.internal/' /etc/fstab
sudo umount -l /mnt/models
sudo mount -a
```

### Scenario C: ZFS pool recovery

```bash
# On storage server
sudo zpool status data_pool
sudo zpool scrub data_pool
# Wait for scrub completion
sudo zpool status data_pool | grep scan

# If disk failed
sudo zpool replace data_pool <old_disk> <new_disk>
```

---

## Restart vLLM after NFS recovery

```bash
# Verify NFS is healthy
ls /mnt/models/

# Restart vLLM containers
cd /opt/vllm && docker compose restart

# Verify health
scripts/deploy/deploy-manager.sh status
```

---

## Prevention

- NFS health check runs every 2 minutes via cron (auto-remount)
- Monitor NFS latency in Prometheus
- Secondary NFS server with rsync replication
- ZFS scrub weekly via cron
- Redundant network paths to storage
