# vLLM Infrastructure — Complete Deployment Workflow

> **Document Version**: 1.0.0  
> **Last Updated**: 2025  
> **Audience**: DevOps / MLOps / Platform Engineers  
> **Estimated Deployment Time**: 4–8 hours (first time), 1–2 hours (repeat)

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites & Pre-flight](#2-prerequisites--pre-flight)
3. [Phase A — Control Plane Bootstrap](#3-phase-a--control-plane-bootstrap)
4. [Phase B — Storage Server Provisioning](#4-phase-b--storage-server-provisioning)
5. [Phase C — Model Download & Registry](#5-phase-c--model-download--registry)
6. [Phase D — GPU Runner Full Provisioning](#6-phase-d--gpu-runner-full-provisioning)
   - [Step D.1 — Base System (Stages 15–30)](#step-d1--base-system-stages-1530)
   - [Step D.2 — NVIDIA Driver (Stages 31–38)](#step-d2--nvidia-driver-stages-3138)
   - [Step D.3 — GPU Configuration (Stages 39–47)](#step-d3--gpu-configuration-stages-3947)
   - [Step D.4 — Docker Engine (Stages 48–54)](#step-d4--docker-engine-stages-4854)
   - [Step D.5 — NVIDIA Container Toolkit (Stages 55–61)](#step-d5--nvidia-container-toolkit-stages-5561)
   - [Step D.6 — NFS Client Mount (Stages 71–76)](#step-d6--nfs-client-mount-stages-7176)
   - [Step D.7 — Monitoring Agents](#step-d7--monitoring-agents)
7. [Phase E — vLLM Deployment](#7-phase-e--vllm-deployment)
8. [Phase F — Monitoring Stack](#8-phase-f--monitoring-stack)
9. [Phase G — Load Balancer Deployment](#9-phase-g--load-balancer-deployment)
10. [Phase H — Verification & Smoke Tests](#10-phase-h--verification--smoke-tests)
11. [Day-2 Operations](#11-day-2-operations)
    - [Rolling Updates](#rolling-updates)
    - [Scaling Out (Add Runner)](#scaling-out-add-runner)
    - [Scaling In (Remove Runner)](#scaling-in-remove-runner)
12. [Error Reference & Troubleshooting](#12-error-reference--troubleshooting)
13. [Rollback Procedures](#13-rollback-procedures)

---

## 1. Architecture Overview

```
                    ┌─────────────────────────┐
                    │      Clients / Apps      │
                    └────────────┬────────────┘
                                 │
                    ┌────────────▼────────────┐
                    │  HAProxy Load Balancer   │
                    │  (lb-01 VIP 10.0.0.100) │
                    │  (lb-02 backup)          │
                    └────┬──────┬─────────┬───┘
                         │      │         │
              ┌──────────▼┐  ┌──▼───────┐ ┌▼──────────┐
              │gpu-runner-01│ │gpu-runner-02│ │gpu-runner-03│
              │ 4×A100-80GB │ │ 4×A100-80GB │ │ 8×H100-80GB │
              │  ┌──────┐   │ │  ┌──────┐   │ │  ┌──────┐   │
              │  │vLLM  │   │ │  │vLLM  │   │ │  │vLLM×2│   │
              │  └──────┘   │ │  └──────┘   │ │  └──────┘   │
              └──────┬──────┘ └──────┬──────┘ └──────┬──────┘
                     │               │               │
              ───────┴───────────────┴───────────────┴──────
                              NFS v4.1 (read-only)
                              Data Network 10.1.0.0/24
              ──────────────────────┬────────────────────────
                                   │
                    ┌──────────────▼──────────────┐
                    │     Storage Servers (NFS)    │
                    │  storage-primary  10.1.0.50  │
                    │  storage-secondary 10.1.0.51 │
                    │  ZFS raidz2 · 8 TB each      │
                    └──────────────────────────────┘
```

**Key principle**: GPU runners are **stateless**. Models live on centralized NFS storage. Runners can be destroyed and rebuilt without data loss.

---

## 2. Prerequisites & Pre-flight

### What You Need Before Starting

| Requirement | Details | Why It Matters |
|---|---|---|
| **Ubuntu 22.04 LTS** | Installed on ALL nodes (bare metal) | Kernel 5.15 has mature NVIDIA driver support; LTS guarantees 5 years of security patches |
| **SSH key access** | Passwordless SSH from control node to all hosts | Ansible communicates over SSH; password prompts break automation |
| **Sudo privileges** | Deploy user in `sudo` group, NOPASSWD | Ansible `become: true` requires passwordless sudo for unattended runs |
| **Network connectivity** | Management (10.0.0.0/24) + Data (10.1.0.0/24) | Separating control traffic from high-bandwidth NFS/model data prevents saturation |
| **DNS resolution** | All hostnames resolvable or `/etc/hosts` populated | Ansible inventory uses hostnames; NFS mounts use IPs but certs need DNS |
| **Internet access** | apt repos, Docker Hub, HuggingFace, NVIDIA repos | Package installation and model downloads require outbound HTTPS |
| **HuggingFace token** | For gated models (Llama, etc.) | Meta requires license acceptance before downloading Llama models |

### Pre-flight Checklist

Run from your control node:

```bash
# 1. Verify SSH access to every host
ansible all -i inventory/hosts.yml -m ping

# 2. Verify sudo
ansible all -i inventory/hosts.yml -m command -a "whoami" --become

# 3. Verify Ubuntu version
ansible all -i inventory/hosts.yml -m command -a "lsb_release -d"

# 4. Verify GPU hardware exists on runners
ansible gpu_runners -i inventory/hosts.yml -m command -a "lspci | grep -i nvidia"

# 5. Verify storage disks exist
ansible storage_servers -i inventory/hosts.yml -m command -a "lsblk"
```

### Possible Errors at This Stage

| Error | Cause | Fix |
|---|---|---|
| `UNREACHABLE! => SSH connection refused` | SSH not running, wrong IP, or firewall | Verify `sshd` is running: `systemctl status sshd`. Check IP in inventory matches `ip addr show` on host. Check firewall: `ufw status` |
| `Permission denied (publickey)` | SSH key not deployed to target host | Copy key: `ssh-copy-id user@host`. Verify `~/.ssh/authorized_keys` on remote host |
| `Missing sudo password` | `ansible_become_password` not set | Add `NOPASSWD: ALL` to `/etc/sudoers.d/deploy-user` or set `ansible_become_password` in vault |
| `lspci shows no NVIDIA` | GPU not seated, BIOS not configured | Reseat GPU physically. Enable PCIe SR-IOV / Above-4G Decoding in BIOS. Check `dmesg | grep -i pci` |
| `lsblk shows no disks` | Storage drives not detected | Check RAID controller, cable connections. Verify drives in BIOS/UEFI |

### Why This Phase Matters

> **If SSH, sudo, or hardware detection fails here, every subsequent step will fail.** This 5-minute check saves hours of debugging cryptic Ansible failures later. Catching a misconfigured inventory hostname now is far better than discovering it mid-way through a 45-minute GPU provisioning run.

---

## 3. Phase A — Control Plane Bootstrap

### Command

```bash
cd /path/to/vllm-infra

# 1. Clone and configure
cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
# Edit hosts.yml with your actual IPs, GPU counts, models

cp ansible/group_vars/all/vault.yml.example ansible/group_vars/all/vault.yml
ansible-vault encrypt ansible/group_vars/all/vault.yml
# Set HF token, Grafana password, Slack webhook, etc.
```

### What Happens

1. **Inventory configuration** — You define every host, its role, network IPs, GPU hardware specs, and which models each runner will serve.
2. **Secrets encryption** — Vault encrypts HuggingFace tokens, Grafana passwords, Slack webhooks so they never appear in plaintext in git.
3. **Version lock** — `versions.lock` pins every component version to prevent drift.

### Step-by-Step Walkthrough

| Step | Action | Why Important |
|---|---|---|
| Copy `hosts.yml.example` → `hosts.yml` | Creates your real inventory | Ansible needs to know every host, IP, and per-host variable |
| Fill in `ansible_host` IPs | Maps hostnames to reachable IPs | Wrong IPs = Ansible cannot connect |
| Set `gpu_count`, `gpu_type` per runner | Tells Ansible what hardware to expect | Used for validation assertions (e.g., "I expected 8 GPUs but found 4") |
| Set `models_to_serve` per runner | Defines which models, ports, GPU assignments | vLLM Docker Compose is generated from this — it controls what actually runs |
| Set `storage_disks` on storage hosts | Tells ZFS which disks to pool | Wrong disk names → ZFS destroys the wrong data |
| Create & encrypt `vault.yml` | Protects secrets | Committing plaintext tokens to git is a security breach |

### Possible Errors

| Error | Cause | Fix |
|---|---|---|
| `ERROR! Decryption failed` when running playbook | Wrong vault password | Re-encrypt: `ansible-vault rekey vault.yml`. Use `--ask-vault-pass` or `ANSIBLE_VAULT_PASSWORD_FILE` |
| `model_to_serve` port conflict | Two models on same port on same host | Ensure each model on a host has a unique `port` (e.g., 8000, 8001) |
| `gpu_ids` overlap | Two models on same host using same GPU | Ensure GPU ID ranges don't overlap (e.g., `0,1,2,3` and `4,5,6,7`) |
| YAML syntax error in inventory | Indentation, wrong types | Run `yamllint ansible/inventory/hosts.yml`. Ports must be integers, not strings |

---

## 4. Phase B — Storage Server Provisioning

### Command

```bash
ansible-playbook -i inventory/hosts.yml playbooks/storage-server.yml --ask-vault-pass
```

### What Happens (Stages 15–30, 62–70, 77)

This playbook provisions the NFS storage servers in this order:

```
base_system role → nfs_server role → monitoring_agents role → verification
```

### Detailed Step Walkthrough

#### B.1 — Base System on Storage Hosts (Stages 15–30)

*Same as GPU runners — see [Step D.1](#step-d1--base-system-stages-1530) for full details.*

Installs 40+ packages, creates service users, hardens SSH, sets sysctl, enables auditd/fail2ban.

#### B.2 — ZFS Pool Creation (Stage 63)

| What | Detail |
|---|---|
| **Action** | Creates a ZFS raidz2 pool named `models` from 4 disks (`/dev/sdb` through `/dev/sde`) |
| **Options** | `ashift=12` (4K sectors), `compression=lz4`, `atime=off`, `recordsize=1M` |
| **Result** | `models/data` dataset mounted at `/srv/models` with quota |

**Why ZFS raidz2?**
- raidz2 = double-parity, survives 2 simultaneous disk failures (RAID-5 only survives 1)
- Model files are large (70B model = ~140 GB), so `recordsize=1M` maximizes sequential read throughput
- `compression=lz4` is nearly free CPU-wise and saves 10-30% on tokenizer configs, JSON metadata
- `atime=off` prevents write amplification from NFS reads updating access timestamps

**Possible Errors:**

| Error | Cause | Fix |
|---|---|---|
| `invalid vdev specification` | Disk paths wrong (e.g., `/dev/sdb` doesn't exist) | Run `lsblk` on storage host. Verify disk names match inventory `storage_disks` |
| `pool already exists` | Re-running playbook after pool created | Safe — role checks `zpool status models` first and skips if exists |
| `cannot open '/dev/sdb': Device or resource busy` | Disk has existing partitions/filesystem | Wipe: `wipefs -a /dev/sdb` (⚠️ DESTROYS DATA). Or use `-f` flag already in role |
| `insufficient replicas` | Fewer than 4 disks for raidz2 | raidz2 needs minimum 4 disks. Add disks or change `raid_level` to `raidz` (single parity) |

#### B.3 — NFS Server Configuration (Stages 64–67)

| What | Detail |
|---|---|
| **Action** | Installs `nfs-kernel-server`, deploys `/etc/exports`, tunes NFS threads to 32 |
| **Export** | `/srv/models` exported read-only to the data network subnet |
| **Tuning** | `sunrpc.tcp_max_slot_table_entries=128`, 16 MB buffer sizes |

**Why 32 NFS threads?**
- Default is 8 threads, which bottlenecks under concurrent model loading from multiple GPU runners
- Each model load streams 140+ GB; 3 runners loading simultaneously need parallel I/O
- 32 threads match the number of CPU cores on a typical storage server

**Why read-only export?**
- GPU runners have NO REASON to write to model storage
- Prevents accidental corruption (rogue container writing to `/mnt/models`)
- Only the storage server itself writes (during model downloads)

**Possible Errors:**

| Error | Cause | Fix |
|---|---|---|
| `exportfs: /srv/models does not exist` | ZFS dataset didn't mount | Check `zfs list` — dataset should show mountpoint `/srv/models` |
| `rpc.nfsd: unable to set any sockets for nfsd` | Port 2049 in use or firewall | Check `ss -tlnp | grep 2049`. Ensure firewall allows NFS ports |
| Clients can connect but reads are slow | NFS threads too low, network saturated | Check `nfsstat -s` for thread utilization. Verify 10 GbE data network |

#### B.4 — Storage Monitoring & Snapshots (Stages 69–70)

| What | Detail |
|---|---|
| **ZFS health cron** | Every 15 minutes, checks `zpool status -x`. Logs warning if pool degraded |
| **Storage usage alert** | Hourly, alerts if storage > 80% capacity |
| **Nightly snapshots** | 2:00 AM, creates daily snapshot, retains 14 days |

**Why snapshots?**
- If a model download corrupts files, you can rollback: `zfs rollback models/data@20250115`
- Snapshots are nearly instant and cost-free (copy-on-write)
- 14-day retention means you can recover from issues discovered days later

#### B.5 — Directory Structure (Stage 77)

Creates model provider directories:

```
/srv/models/
├── meta-llama/
├── mistralai/
├── Qwen/
├── microsoft/
└── .registry/          ← Model catalog JSON
```

#### B.6 — Post-Verification

The playbook verifies:
1. `zpool status models` — Pool is ONLINE and healthy
2. `exportfs -v` — Exports are visible and correctly configured

**✅ Success criteria**: ZFS pool ONLINE, NFS exports visible, no errors.

---

## 5. Phase C — Model Download & Registry

### Command

```bash
# Download first model
ansible-playbook -i inventory/hosts.yml playbooks/model-download.yml \
  -e model_id=meta-llama/Llama-3.1-70B-Instruct \
  -e model_version=v1 \
  --ask-vault-pass

# Download second model
ansible-playbook -i inventory/hosts.yml playbooks/model-download.yml \
  -e model_id=Qwen/Qwen2.5-72B-Instruct \
  -e model_version=v1 \
  --ask-vault-pass
```

### What Happens (Stages 78–85)

| Step | Stage | Action | Duration |
|---|---|---|---|
| 1 | 78 | Install `huggingface_hub` CLI on storage server | ~30 sec |
| 2 | 78 | Create target directory `/srv/models/meta-llama/Llama-3.1-70B-Instruct/v1` | instant |
| 3 | 78 | Login to HuggingFace (for gated models like Llama) | ~2 sec |
| 4 | 78 | Download model files via `huggingface-cli download` | **30–120 min** per model |
| 5 | 79 | Generate SHA256 checksums for all `.safetensors` and `.bin` files | ~5 min |
| 6 | 80 | Write `.metadata.json` with download date, host, status | instant |
| 7 | 81 | Update model catalog at `.registry/catalog.json` | instant |

### Why Each Step Matters

**HuggingFace login (Step 3)**
- Llama 3.1 is a "gated" model — Meta requires you to accept a license on huggingface.co before downloading
- Without login, you'll get `401 Unauthorized` and the download fails silently (or with a confusing error)

**SHA256 checksums (Step 5)**
- Model files are enormous — a single bit flip during download = GPU crash or garbage output
- Checksums let you verify integrity: `cd /srv/models/meta-llama/... && sha256sum -c .checksums.sha256`
- Essential for DR scenarios: after restoring from backup, verify nothing is corrupted

**Metadata JSON (Step 6)**
- Records WHEN the model was downloaded, from WHERE, and its quantization type
- Critical for auditing: "Which version of Llama are we running?" → check `.metadata.json`

**Model catalog (Step 7)**
- Central registry of all available models on the storage cluster
- Used by automation to know what's available without scanning the filesystem

### Possible Errors

| Error | Cause | Fix |
|---|---|---|
| `401 Client Error: Unauthorized` | HuggingFace token invalid or missing | Verify `vault_hf_token` in vault.yml. Visit huggingface.co and accept model license. Regenerate token at hf.co/settings/tokens |
| `403 Forbidden` | Model license not accepted | Go to the model page on huggingface.co, click "Agree and access repository" |
| Download hangs / stalls | Network issues, HF rate limiting | The task has `async: 7200` (2-hour timeout). Check `/var/log/model-download-*.log`. Retry will resume (huggingface-cli supports resume) |
| `No space left on device` | ZFS pool full | Check `zfs list -o used,avail models/data`. Delete old model versions. Expand pool with `zpool add` |
| Checksum mismatch after download | Corrupted download, disk issue | Delete model directory, re-download. Check `zpool status` for disk errors |
| `model_id is required` | Forgot `-e model_id=...` | Required parameter — must pass model ID on command line |

### Time Expectations

| Model | Size | Download Time (1 Gbps) | Download Time (10 Gbps) |
|---|---|---|---|
| Llama-3.1-8B-Instruct | ~16 GB | ~3 min | ~15 sec |
| Llama-3.1-70B-Instruct | ~140 GB | ~20 min | ~2 min |
| Qwen2.5-72B-Instruct | ~145 GB | ~20 min | ~2 min |
| Llama-3.1-405B | ~800 GB | ~2 hours | ~12 min |

> **⚠️ Critical**: Download the models BEFORE provisioning GPU runners. The runners mount NFS read-only and cannot download models themselves.

---

## 6. Phase D — GPU Runner Full Provisioning

### Command

```bash
ansible-playbook -i inventory/hosts.yml playbooks/gpu-runner-full.yml --ask-vault-pass
```

### What Happens

This is the **largest and most complex** playbook. It chains 7 roles in strict order:

```
pre_tasks (validate Ubuntu + show plan)
  ↓
base_system (Stages 15–30)
  ↓
nvidia_driver (Stages 31–38)
  ↓
gpu_config (Stages 39–47)
  ↓
docker_engine (Stages 48–54)
  ↓
nvidia_container_toolkit (Stages 55–61)
  ↓
nfs_client (Stages 71–76)
  ↓
monitoring_agents
  ↓
post_tasks (verify GPU count, Docker GPU, NFS mount)
```

**Each role depends on the previous one.** You CANNOT skip or reorder them.

### Pre-tasks — Validation Gate

Before anything runs:

```yaml
- assert:
    that: ansible_distribution == 'Ubuntu' and ansible_distribution_version == '22.04'
    fail_msg: "This playbook requires Ubuntu 22.04 LTS"
```

**Why**: NVIDIA driver packages, kernel modules, and Docker packages are distribution-specific. Running on Ubuntu 20.04 or Debian will install wrong packages or fail to compile kernel modules.

**Possible Error**:

| Error | Cause | Fix |
|---|---|---|
| `Assertion failed: requires Ubuntu 22.04 LTS` | Wrong OS version | Reinstall with Ubuntu 22.04.x LTS Server |

---

### Step D.1 — Base System (Stages 15–30)

**Duration**: ~5–10 minutes per host

#### Stage 17: Kernel Pinning

| What | Detail |
|---|---|
| **Action** | Installs specific kernel `linux-image-5.15.0-105-generic` and marks it `hold` |
| **Why** | NVIDIA drivers compile against a specific kernel ABI. An auto-updated kernel will **break** the GPU driver, causing `nvidia-smi` to fail with `NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver` |
| **Risk of skipping** | Next `apt upgrade` installs kernel 5.15.0-120, NVIDIA module doesn't load, GPUs disappear |

**Possible Errors:**

| Error | Cause | Fix |
|---|---|---|
| `E: Unable to locate package linux-image-5.15.0-105-generic` | Kernel version no longer in repos | Check available kernels: `apt-cache search linux-image-5.15.0`. Update `kernel_package` variable |
| System already on a different kernel | Pre-existing installation | May need reboot after installing pinned kernel: `reboot`, then re-run playbook |

#### Stage 19: Base Packages (40+ packages)

| What | Detail |
|---|---|
| **Action** | Installs build tools, monitoring utilities, NFS client, security tools, Python, etc. |
| **Key packages** | `build-essential` (for DKMS), `nfs-common`, `chrony` (NTP), `auditd`, `fail2ban`, `pciutils` |
| **Why** | `build-essential` is required by NVIDIA DKMS to compile kernel modules. `pciutils` provides `lspci` for GPU detection. `chrony` ensures clock sync (logs from different hosts must correlate). |

**Possible Errors:**

| Error | Cause | Fix |
|---|---|---|
| `E: Unable to fetch some archives` | APT mirror down or DNS failure | Check `/etc/resolv.conf`. Try `apt update` manually. Switch mirrors in `/etc/apt/sources.list` |
| `dpkg was interrupted` | Previous apt run crashed | Run `dpkg --configure -a` then retry |
| `Could not get lock /var/lib/dpkg/lock` | Another apt process running | `kill $(lsof -t /var/lib/dpkg/lock)` or wait for `unattended-upgrades` to finish |

#### Stage 20: Service Users

| What | Detail |
|---|---|
| **Action** | Creates `vllm` group, `vllm-user` (system account, no login shell), `node-exporter` user |
| **Why** | Running vLLM as root is a security risk. Dedicated service accounts follow principle of least privilege. |

#### Stage 21: Timezone & Locale

| What | Detail |
|---|---|
| **Action** | Sets timezone to UTC, locale to `en_US.UTF-8` |
| **Why** | All nodes on UTC means log timestamps are directly comparable. UTF-8 locale prevents Python encoding errors. |

#### Stage 22: SSH Hardening

| What | Detail |
|---|---|
| **Action** | Deploys hardened `sshd_config` — disables root login, password auth, X11 forwarding. Restricts to `sudo` and `deploy` groups. Max 3 auth tries. |
| **Why** | GPU servers are high-value targets. SSH is the primary attack vector. Hardening prevents brute force and lateral movement. |
| **Validation** | Config is validated with `sshd -t -f %s` before applying — if syntax is invalid, the change is **not applied** (preventing lockout) |

**⚠️ CRITICAL ERROR WARNING:**

| Error | Cause | Fix |
|---|---|---|
| **Locked out of server** | SSH hardening applied but your user is NOT in `sudo` or `deploy` group | **BEFORE running**: Ensure your deploy user is in the `sudo` group. If locked out: access via IPMI/iDRAC console, edit `/etc/ssh/sshd_config`, restore old config from backup (Ansible creates `.bak`) |

#### Stage 23: Kernel Sysctl Tuning

| What | Detail |
|---|---|
| **Action** | Applies 20+ sysctl parameters for security + performance |
| **Security** | TCP syncookies, rp_filter, disable redirects, restrict dmesg, ASLR level 2 |
| **Performance** | 16 MB network buffers (for NFS), low swappiness (10), dirty_ratio 15% |
| **Why** | Default 128 KB network buffers bottleneck NFS reads. Low swappiness keeps GPU memory-mapped data in RAM. |

#### Stages 24–26: Security Stack

| What | Action | Why |
|---|---|---|
| **fail2ban** | Bans IPs after 5 failed SSH attempts for 1 hour | Automated brute-force protection |
| **Unattended upgrades** | Auto-installs security patches, but **blacklists** nvidia/docker/kernel packages | Security patches without breaking GPU stack |
| **Auditd** | Monitors: sudo usage, Docker socket access, GPU device access, model file reads | Compliance & forensics — know who accessed what |

**Critical design decision in unattended-upgrades:**
```
Unattended-Upgrade::Package-Blacklist {
    "linux-image-*";    ← Kernel updates break NVIDIA
    "nvidia-*";         ← Driver updates break CUDA
    "cuda-*";           ← CUDA updates break vLLM
    "docker-*";         ← Docker updates break containers
};
```
This lets security patches flow automatically while protecting the GPU software stack from automatic updates.

#### Stage 29: Login Banner & MOTD

| What | Detail |
|---|---|
| **Action** | Sets legal warning banner + dynamic MOTD showing hostname, IP, GPU count, Docker version, vLLM version, NFS mount status |
| **Why** | Legal banner is required for compliance (unauthorized access warning). Dynamic MOTD gives operators instant situational awareness when they SSH in. |

---

### Step D.2 — NVIDIA Driver (Stages 31–38)

**Duration**: ~10–15 minutes per host (includes DKMS compile)

This is the **most failure-prone** step in the entire deployment. GPU driver issues cause more outages than any other component.

#### Stage 31: Blacklist Nouveau

| What | Detail |
|---|---|
| **Action** | Creates `/etc/modprobe.d/blacklist-nouveau.conf` with `blacklist nouveau` + `options nouveau modeset=0` |
| **Why** | Nouveau is the open-source NVIDIA driver. It conflicts with the proprietary driver. If both are loaded, `nvidia-smi` fails or GPUs show wrong device. |
| **Followed by** | `update-initramfs -u` to rebuild the boot image without nouveau |

**Possible Errors:**

| Error | Cause | Fix |
|---|---|---|
| `update-initramfs` hangs | Very large initramfs, slow disk | Wait — can take 2-3 minutes on older hardware |
| Nouveau still loaded after reboot | Initramfs not updated properly | Run `lsmod | grep nouveau`. If loaded: `rmmod nouveau`, then rebuild initramfs and reboot |

#### Stage 32: NVIDIA Repository

| What | Detail |
|---|---|
| **Action** | Adds NVIDIA's official CUDA repository for Ubuntu 22.04 |
| **Why** | Ubuntu's default repos have older NVIDIA drivers that don't support latest GPU features |

**Possible Errors:**

| Error | Cause | Fix |
|---|---|---|
| `GPG key retrieval failed` | NVIDIA CDN unreachable | Check DNS, try `curl -I https://developer.download.nvidia.com`. May need proxy configuration |
| `The repository ... does not have a Release file` | Wrong Ubuntu codename | Verify `lsb_release -cs` returns `jammy` |

#### Stage 33: Driver Installation

| What | Detail |
|---|---|
| **Action** | Installs `nvidia-driver-550` + `nvidia-utils-550` and marks them `hold` |
| **Version** | 550.90.07 — pinned in `versions.lock` |
| **DKMS** | Driver compiles a kernel module against your running kernel (this is why `build-essential` and matching kernel headers were installed earlier) |

**Possible Errors:**

| Error | Cause | Fix |
|---|---|---|
| `DKMS: build failed` | Missing kernel headers, wrong kernel version | Verify: `dpkg -l | grep linux-headers-$(uname -r)`. Install matching headers |
| `The following packages have unmet dependencies` | Version conflict with existing NVIDIA packages | Purge all: `apt purge 'nvidia-*' 'libnvidia-*'` then retry |
| Takes very long (>10 min) | DKMS kernel module compilation | Normal on first install. DKMS compiles C code against kernel — CPU intensive |

#### Stage 34: CUDA Toolkit

| What | Detail |
|---|---|
| **Action** | Installs `cuda-toolkit-12-4` |
| **Why** | vLLM requires CUDA runtime libraries. The toolkit provides `nvcc`, `libcudart`, `libcublas`, etc. |
| **Note** | We install the toolkit, NOT the full CUDA package (which includes another driver copy) |

#### Stage 35: Environment Variables

| What | Detail |
|---|---|
| **Action** | Adds CUDA paths to system-wide profile: `PATH=/usr/local/cuda-12.4/bin:$PATH`, `LD_LIBRARY_PATH=/usr/local/cuda-12.4/lib64` |
| **Why** | Without this, `nvcc` and CUDA libraries aren't found by Docker builds or system utilities |

#### Stage 36: NVIDIA Persistenced

| What | Detail |
|---|---|
| **Action** | Enables `nvidia-persistenced` systemd service |
| **Why** | Without persistenced, the GPU driver unloads when no processes use it, then reloads on next access. This causes a **2-5 second latency spike** on the first inference after idle. Persistenced keeps the driver loaded 24/7. |

#### Stage 37: Fabric Manager (Multi-GPU)

| What | Detail |
|---|---|
| **Action** | Enables `nvidia-fabricmanager` service on NVLink/NVSwitch systems |
| **Why** | Required for GPU-to-GPU communication on H100 NVSwitch systems. Without it, tensor parallelism across 8 GPUs will fail or fall back to slow PCIe transfers. |
| **Conditional** | Only runs on hosts where `nvlink: true` in inventory |

**Possible Errors:**

| Error | Cause | Fix |
|---|---|---|
| `nvidia-fabricmanager.service not found` | Package not installed, or A100 without NVSwitch | Only needed for NVSwitch topologies. A100 with NVLink bridges doesn't need it |

#### Stage 38: Verification

| What | Detail |
|---|---|
| **Action** | Runs `nvidia-smi`, displays GPU topology (`nvidia-smi topo -m`), asserts GPU count matches inventory |
| **Assertion** | `nvidia-smi --query-gpu=count --format=csv,noheader | head -1` must equal `{{ gpu_count }}` |

**This is the CRITICAL validation gate.** If this fails, nothing downstream will work.

**Possible Errors:**

| Error | Cause | Fix |
|---|---|---|
| `nvidia-smi: command not found` | Driver not installed properly | Rerun the role. Check `dkms status` |
| `NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver` | Driver module not loaded | `modprobe nvidia`. If fails: check `dmesg | grep nvidia`. May need reboot |
| `Failed to initialize NVML: Driver/library version mismatch` | Kernel module version ≠ userspace library | **Reboot required**: `sudo reboot`. The old kernel module is still loaded |
| GPU count mismatch (expected 8, found 4) | GPU not seated, PCIe slot disabled in BIOS, or GPU hardware failure | Check `lspci | grep -i nvidia`. Reseat GPU. Check BIOS PCIe settings. Run `nvidia-smi -q` for detailed status |

---

### Step D.3 — GPU Configuration (Stages 39–47)

**Duration**: ~2 minutes per host

#### Stage 39–40: Power Management

| What | Detail |
|---|---|
| **Action** | Sets power limit to 300W per GPU via `nvidia-smi -pl 300` |
| **Why** | Default power limit on A100 is 400W. Reducing to 300W drops temperature by 10-15°C with only 5-8% performance loss. This extends GPU lifespan and prevents thermal throttling. |
| **Persistence** | Deployed as a systemd unit that runs at boot |

#### Stage 41: ECC Memory

| What | Detail |
|---|---|
| **Action** | Enables ECC (Error Correcting Code) memory on all GPUs |
| **Why** | GPU memory bit flips cause silent data corruption — the model produces garbage output without any error. ECC detects and corrects single-bit errors. |
| **Trade-off** | ECC reduces available VRAM by ~6% (80 GB → ~75 GB usable) |

#### Stage 42: Compute Mode

| What | Detail |
|---|---|
| **Action** | Sets compute mode to `EXCLUSIVE_PROCESS` (one process per GPU) or `DEFAULT` |
| **Why** | `EXCLUSIVE_PROCESS` prevents another container from accidentally using an already-assigned GPU |

#### Stage 44: NUMA Configuration

| What | Detail |
|---|---|
| **Action** | Configures NUMA (Non-Uniform Memory Access) affinity for GPUs |
| **Why** | On dual-socket systems, GPUs physically connect to specific CPU sockets. If a GPU on socket 0 serves memory from socket 1, latency doubles. Correct NUMA affinity ensures GPU memory transfers take the shortest path. |

#### Stage 47: Thermal Monitoring Cron

| What | Detail |
|---|---|
| **Action** | Cron job every 5 minutes checks GPU temperature; logs warning if > 80°C |
| **Why** | Sustained temperatures above 85°C cause thermal throttling (automatic frequency reduction). Above 95°C triggers emergency shutdown. Early warning prevents production impact. |

**Possible Errors:**

| Error | Cause | Fix |
|---|---|---|
| `nvidia-smi -pl 300: not supported` | GPU model doesn't support power management | Some consumer GPUs lack this feature. Only datacenter GPUs (A100, H100, A6000, etc.) support it |
| Temperature already high at idle | Airflow problem, fan failure | Check server ambient temperature. Verify fans are operational. Check for blocked airflow |

---

### Step D.4 — Docker Engine (Stages 48–54)

**Duration**: ~3–5 minutes per host

#### Stage 48: Docker Repository

| What | Detail |
|---|---|
| **Action** | Adds Docker's official GPG key and APT repository |
| **Why** | Ubuntu's `docker.io` package is outdated. Docker's official repo provides current versions with GPU runtime support. |

#### Stage 49: Docker Installation

| What | Detail |
|---|---|
| **Action** | Installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-compose-plugin` and marks them `hold` |
| **Why hold** | Prevents `apt upgrade` from updating Docker. Docker updates can change behavior, break compose compatibility, or modify the storage driver. |

#### Stage 50: Daemon Configuration

| What | Detail |
|---|---|
| **Action** | Deploys `/etc/docker/daemon.json` with production settings |

Key settings and why:

| Setting | Value | Why |
|---|---|---|
| `data-root` | `/data/docker` | Separates Docker data from root filesystem. Prevents container images filling `/` |
| `storage-driver` | `overlay2` | Most performant storage driver for Linux. Copy-on-write with minimal overhead |
| `log-driver` | `json-file` | Compatible with Loki/Promtail log collection |
| `max-size` | `100m`, `max-file: 5` | Prevents a chatty container from filling disk. 500 MB max per container |
| `live-restore` | `true` | **Critical**: Containers survive Docker daemon restart. Without this, upgrading dockerd kills all vLLM containers |
| `no-new-privileges` | `true` | Prevents privilege escalation inside containers |
| `memlock: -1` | Unlimited | GPU memory must be pinned (locked). Without unlimited memlock, CUDA fails to allocate GPU memory |
| `nofile: 65536` | 65K open files | vLLM opens many files (model shards, sockets). Default 1024 causes "Too many open files" |
| `metrics-addr` | `0.0.0.0:9323` | Exposes Docker engine metrics for Prometheus scraping |

#### Stage 53: User Permissions

| What | Detail |
|---|---|
| **Action** | Adds deploy user to `docker` group |
| **Why** | Allows running Docker commands without `sudo`. Required for Ansible tasks that use `community.docker` modules |

#### Stage 54: Systemd Overrides

| What | Detail |
|---|---|
| **Action** | Sets `TimeoutStartSec=300`, `Restart=on-failure`, unlimited `LimitNOFILE/NPROC/CORE` |
| **Why** | Default 90-second start timeout is too short when Docker must load a 20 GB vLLM image. 300 seconds prevents systemd from killing Docker during large image loads. |

#### Stage 52: Weekly Cleanup

| What | Detail |
|---|---|
| **Action** | Sunday 3 AM cron: `docker system prune -af --filter 'until=168h'` |
| **Why** | Old images, stopped containers, and unused networks accumulate. A single vLLM image is ~10 GB. Without cleanup, `/data/docker` fills up within weeks. The 168-hour filter preserves anything used in the last week. |

**Possible Errors:**

| Error | Cause | Fix |
|---|---|---|
| `docker: Cannot connect to the Docker daemon` | Docker not started after install | `systemctl start docker`. Check `journalctl -u docker` for errors |
| `Error starting daemon: error initializing graphdriver: overlay2: device ... not supported` | Filesystem doesn't support overlay2 | Use ext4 or xfs for `/data/docker`. Btrfs has issues with overlay2 |
| `docker-compose-plugin: Depends: docker-ce-cli` | Version mismatch | `apt install docker-ce docker-ce-cli containerd.io docker-compose-plugin` all together |

---

### Step D.5 — NVIDIA Container Toolkit (Stages 55–61)

**Duration**: ~3 minutes per host

#### Stage 55–57: Installation & Configuration

| What | Detail |
|---|---|
| **Action** | Installs `nvidia-container-toolkit` (v1.16.1), configures it as Docker's default runtime, generates CDI (Container Device Interface) config |
| **Why** | This is the **bridge** between Docker and GPUs. Without it, `docker run --gpus all` doesn't work. CDI provides a standard device interface that maps GPU devices into containers. |

#### Stage 58: Default Runtime

| What | Detail |
|---|---|
| **Action** | Sets `"default-runtime": "nvidia"` in Docker daemon config |
| **Why** | Without this, every `docker run` command needs `--gpus all`. Setting nvidia as default means ALL containers automatically get GPU access. This is essential because Docker Compose doesn't have a good way to pass `--gpus`. |

#### Stage 61: GPU Isolation Test

| What | Detail |
|---|---|
| **Action** | Runs `docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi` |
| **Why** | **The definitive test** — if GPUs are visible inside a container, the entire NVIDIA stack (driver + toolkit + runtime) is working |

**Possible Errors:**

| Error | Cause | Fix |
|---|---|---|
| `docker: Error response from daemon: could not select device driver "nvidia"` | nvidia-container-toolkit not installed or Docker not restarted | Install toolkit, then `systemctl restart docker` |
| `nvidia-container-cli: initialization error: nvml error: driver not loaded` | NVIDIA driver not loaded in kernel | `modprobe nvidia`. Check `dmesg | grep nvidia`. May need reboot |
| `Failed to initialize NVML: Unknown Error` inside container | cgroup configuration issue | Add `"exec-opts": ["native.cgroupdriver=systemd"]` to daemon.json |

---

### Step D.6 — NFS Client Mount (Stages 71–76)

**Duration**: ~1 minute per host

#### Stage 71–73: Mount Configuration

| What | Detail |
|---|---|
| **Action** | Installs NFS client, creates `/mnt/models`, adds fstab entry, mounts NFS share |
| **Mount options** | `ro,hard,intr,nfsvers=4.1,rsize=1048576,wsize=1048576,timeo=600,retrans=3` |

Mount option breakdown:

| Option | Value | Why |
|---|---|---|
| `ro` | Read-only | GPU runners must never write to model storage |
| `hard` | Hard mount | If NFS server unreachable, operations **wait** instead of failing. Prevents vLLM from getting I/O errors |
| `intr` | Interruptible | Allows killing a process stuck waiting on NFS (without this, processes become unkillable) |
| `nfsvers=4.1` | NFS v4.1 | Session-based protocol with better security and performance than v3 |
| `rsize=1048576` | 1 MB read size | Large reads = fewer round trips when loading 140 GB model files |
| `timeo=600` | 60-second timeout | Tolerates brief network glitches without failing |
| `retrans=3` | 3 retries | Combined with hard mount, gives 3 × 60 = 180 seconds to recover from NFS issues |

#### Stage 74: Validation

| What | Detail |
|---|---|
| **Action** | `mountpoint -q /mnt/models` and `ls -la /mnt/models/` |
| **Why** | Confirms mount is active AND readable. A mount can exist but be stale (shows `ls: cannot access: Stale file handle`) |

#### Stage 76: Health Monitor

| What | Detail |
|---|---|
| **Action** | Deploys a script that runs every 2 minutes via cron. Checks if mount is active. If stale, performs `umount -l` then `mount`. |
| **Why** | NFS mounts can go stale after network interruptions. Without auto-recovery, vLLM containers get I/O errors and crash. The health check automatically recovers without human intervention. |

**Possible Errors:**

| Error | Cause | Fix |
|---|---|---|
| `mount.nfs4: Connection timed out` | NFS server unreachable on data network | Verify: `ping 10.1.0.50` (from data interface). Check NFS server: `systemctl status nfs-kernel-server`. Check firewall on storage server |
| `mount.nfs4: access denied by server` | IP not in NFS exports, or wrong export path | On storage server: check `exportfs -v`. Ensure GPU runner's data IP is in the allowed subnet |
| `Stale file handle` on existing mount | NFS server was restarted or export changed | `umount -l /mnt/models && mount /mnt/models`. The health check script handles this automatically |
| `mount point does not exist` | Directory not created | Should be created by Stage 72. Manual: `mkdir -p /mnt/models` |
| Mount succeeds but directory is empty | Wrong export path, or models not downloaded yet | On storage server: `ls /srv/models/`. Ensure Phase C (model download) completed |

---

### Step D.7 — Monitoring Agents

**Duration**: ~2 minutes per host

| What | Detail |
|---|---|
| **Action** | Deploys `node_exporter` (system metrics), `dcgm-exporter` (GPU metrics), `promtail` (log shipping) |
| **Why** | Without monitoring agents, the central Prometheus/Grafana stack has no data. You'll be blind to GPU temperature, memory usage, inference latency, and errors. |

---

### Post-tasks — Final Validation Gate

After ALL roles complete, the playbook runs three critical checks:

| Check | What | Pass Criteria |
|---|---|---|
| GPU count | `nvidia-smi --query-gpu=count` | Matches inventory `gpu_count` |
| Docker GPU | `docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi` | Exit code 0, GPUs visible |
| NFS mount | `mountpoint -q /mnt/models` | Mount active |

**If ANY post-task fails**, the runner is NOT ready for vLLM deployment. Fix the issue before proceeding.

---

## 7. Phase E — vLLM Deployment

### Command

```bash
ansible-playbook -i inventory/hosts.yml playbooks/deploy-vllm.yml --ask-vault-pass
```

### What Happens (Stages 93–104)

This playbook deploys vLLM containers using a **rolling strategy** (`serial: 1`) — one runner at a time.

```
For each GPU runner (one at a time):
  ├── Pre-checks
  │   ├── NFS mount active?
  │   ├── Model files exist at specified path?
  │   └── GPU health check passes?
  │
  ├── vllm_deploy role
  │   ├── Create directories (/opt/vllm/...)
  │   ├── Deploy Docker Compose (from models_to_serve)
  │   ├── Deploy .env file
  │   ├── Deploy health check script
  │   ├── Deploy & run pre-flight check
  │   ├── Pull vLLM image (vllm/vllm-openai:v0.8.3)
  │   └── Start containers
  │
  └── Post-checks
      ├── Wait for containers to become healthy (up to 5 min)
      ├── Smoke test /v1/models endpoint
      └── Display summary
```

### Pre-checks — Why They Matter

**NFS mount check**: If NFS is not mounted, vLLM starts but immediately crashes trying to read the model. The error message inside the container is cryptic (`FileNotFoundError`) — checking beforehand gives a clear error.

**Model files check**: Even if NFS is mounted, the specific model path might not exist (model not downloaded, wrong version string). Better to fail fast with "Model files not found at `/mnt/models/meta-llama/Llama-3.1-70B-Instruct/v1`" than wait 5 minutes for vLLM to timeout.

**GPU health check**: If a GPU is already in error state (ECC errors, thermal throttling), deploying vLLM will just result in CUDA errors.

### Docker Compose Generation

The role generates `docker-compose.yml` from the `models_to_serve` variable in inventory. For `gpu-runner-03` (serving 2 models):

```yaml
# Generated for gpu-runner-03
services:
  vllm-llama-3-1-70b-instruct:
    image: vllm/vllm-openai:v0.8.3
    ports: ["8000:8000"]
    environment:
      - CUDA_VISIBLE_DEVICES=0,1,2,3
    volumes:
      - /mnt/models:/models:ro
    deploy:
      resources:
        reservations:
          devices:
            - capabilities: [gpu]
              device_ids: ['0','1','2','3']

  vllm-qwen2-5-72b-instruct:
    image: vllm/vllm-openai:v0.8.3
    ports: ["8001:8000"]
    environment:
      - CUDA_VISIBLE_DEVICES=4,5,6,7
    volumes:
      - /mnt/models:/models:ro
    deploy:
      resources:
        reservations:
          devices:
            - capabilities: [gpu]
              device_ids: ['4','5','6','7']
```

### Pre-flight Check Script

Runs automatically before starting containers. Verifies:
1. **GPU health** — `nvidia-smi` responds, no GPU above 85°C
2. **NFS mount** — `/mnt/models` mounted and readable
3. **Docker** — daemon running
4. **NVIDIA runtime** — GPUs accessible inside Docker
5. **Disk space** — root filesystem not full (>90% triggers failure)

### Container Startup & Model Loading

| Phase | What Happens | Duration |
|---|---|---|
| Image pull | Downloads `vllm/vllm-openai:v0.8.3` (~10 GB) | 1–5 min (first time) |
| Container start | Docker creates container with GPU reservation | ~5 sec |
| Model loading | vLLM reads model from NFS into GPU VRAM | **2–10 min** (depends on model size + NFS speed) |
| Warmup | First inference request compiles CUDA kernels | ~30 sec |
| Health check passes | `/health` returns 200 | After model load complete |

### Post-checks

| Check | Method | Timeout |
|---|---|---|
| Container health | `docker inspect --format='{{.State.Health.Status}}'` | Polls every 15s for up to 5 min (40 retries) |
| Smoke test | `curl http://localhost:PORT/v1/models` | Must return 200 with model ID |

### Possible Errors

| Error | Cause | Fix |
|---|---|---|
| `CUDA out of memory` | Model too large for available VRAM, or `gpu_memory_utilization` too high | Reduce `gpu_memory_utilization` from 0.92 to 0.85. Or reduce `max_model_len`. Or use quantized model |
| `FileNotFoundError: /models/meta-llama/...` | Model path in inventory doesn't match actual path on NFS | SSH to runner, `ls /mnt/models/meta-llama/`. Fix path in `hosts.yml` |
| Health check never passes (timeout after 5 min) | Model loading is slow, or OOM killed | Check `docker logs vllm-<model-name>`. Look for OOM or CUDA errors. Check `dmesg` for OOM killer |
| `torch.cuda.OutOfMemoryError` | Tensor parallel size wrong, or another process using GPU | Verify `CUDA_VISIBLE_DEVICES` is correct. Check `nvidia-smi` for other processes on those GPUs |
| Container starts then immediately exits | Configuration error in env file | `docker logs vllm-<name>`. Common: wrong model path, invalid dtype, incompatible vLLM version |
| Port already in use | Another service on port 8000/8001 | `ss -tlnp | grep 8000`. Kill or reconfigure conflicting service |
| `Error response from daemon: Conflict. The container name ... is already in use` | Previous deployment left containers | `docker rm -f vllm-<name>` or `docker compose down` in `/opt/vllm/compose/` |

### Why Rolling Deployment (`serial: 1`)

- If deployment fails on `gpu-runner-01`, `gpu-runner-02` and `gpu-runner-03` are still serving traffic
- If we deployed to ALL runners simultaneously and there's a bug, **100% of capacity goes down**
- Rolling deployment = maximum availability during deployments

---

## 8. Phase F — Monitoring Stack

### Command

```bash
ansible-playbook -i inventory/hosts.yml playbooks/monitoring-stack.yml --ask-vault-pass
```

### What Happens (Stages 146–175)

Deploys the full observability stack on the monitoring server (`mon-01`):

| Component | Port | Purpose |
|---|---|---|
| **Prometheus** | 9090 | Metrics collection & alerting engine. Scrapes GPU runners, storage, LBs every 15s |
| **Grafana** | 3000 | Dashboards & visualization. 5 pre-built dashboards |
| **Alertmanager** | 9093 | Alert routing — sends to Slack, PagerDuty, email based on severity |
| **Loki** | 3100 | Log aggregation — collects logs from all hosts via Promtail agents |

### What Gets Monitored

| Metric Source | Collected By | Key Metrics |
|---|---|---|
| GPU temperature, power, memory, utilization | DCGM Exporter → Prometheus | `DCGM_FI_DEV_GPU_TEMP`, `DCGM_FI_DEV_FB_USED` |
| vLLM inference latency, throughput, queue | vLLM `/metrics` → Prometheus | `vllm:request_latency`, `vllm:num_requests_running` |
| CPU, RAM, disk, network | Node Exporter → Prometheus | `node_cpu_seconds_total`, `node_filesystem_avail_bytes` |
| NFS latency, ops/sec | Node Exporter → Prometheus | `node_nfs_requests_total` |
| Docker container status | Docker metrics → Prometheus | `engine_daemon_container_states_containers` |
| Application logs | Promtail → Loki | vLLM container logs, system logs |

### 21 Alert Rules (Pre-configured)

Examples of what triggers alerts:

| Alert | Condition | Severity |
|---|---|---|
| `GPUTemperatureHigh` | GPU > 85°C for 5 min | Critical |
| `GPUMemoryExhausted` | GPU VRAM > 95% for 10 min | Warning |
| `vLLMContainerDown` | vLLM container not running for 2 min | Critical |
| `vLLMHighLatency` | P99 latency > 30s for 5 min | Warning |
| `NFSMountStale` | NFS mount check fails for 3 min | Critical |
| `DiskSpaceLow` | Any filesystem > 85% | Warning |
| `NodeDown` | Host unreachable for 5 min | Critical |

### Post-Deployment Verification

The playbook waits for each service to be ready:
- Prometheus: `http://localhost:9090/-/ready` returns 200
- Grafana: `http://localhost:3000/api/health` returns 200
- Loki: `http://localhost:3100/ready` returns 200

### Possible Errors

| Error | Cause | Fix |
|---|---|---|
| Prometheus won't start | Config syntax error | `promtool check config prometheus.yml` |
| Grafana shows "No data" | Datasource misconfigured | Verify Prometheus URL in Grafana datasource settings |
| Alertmanager not sending alerts | Slack webhook URL wrong | Test webhook: `curl -X POST -d '{"text":"test"}' WEBHOOK_URL` |
| Loki OOM killed | Insufficient memory for log ingestion | Increase memory limit in compose. Default: 2 GB minimum |
| Targets show DOWN in Prometheus | Monitoring agents not running on targets, or firewall | On target: `curl localhost:9100/metrics` (node_exporter). Check firewall allows 9100, 9400 |

---

## 9. Phase G — Load Balancer Deployment

### Command

```bash
ansible-playbook -i inventory/hosts.yml playbooks/load-balancer.yml --ask-vault-pass
```

### What Happens (Stages 141–146)

Deploys HAProxy + Keepalived on two load balancer nodes in a rolling fashion (`serial: 1`):

| Component | Purpose |
|---|---|
| **HAProxy 2.8.10** | L7 load balancing — routes `/v1/chat/completions`, `/v1/completions`, `/v1/models` to healthy GPU runners |
| **Keepalived** | VIP failover — if `lb-01` dies, `lb-02` takes over the VIP `10.0.0.100` within seconds |

### Why a Load Balancer?

Without LB:
- Clients must know individual runner IPs
- If a runner goes down, clients get errors
- No request distribution, one runner gets hammered

With LB:
- Single VIP endpoint: `http://10.0.0.100:8000/v1/chat/completions`
- Automatic failover — clients never see runner failures
- Health-checked backends — unhealthy runners automatically removed
- Rate limiting — prevents any single client from overwhelming the fleet

### Pre-tasks

The playbook:
1. Gathers facts from ALL GPU runners (to know their IPs and model ports)
2. Builds a unique model list across the fleet
3. Passes this to HAProxy template to generate backend configurations

### Possible Errors

| Error | Cause | Fix |
|---|---|---|
| `Cannot bind socket [0.0.0.0:8000]` | Port already in use | Check `ss -tlnp | grep 8000`. Another process (or previous HAProxy) is binding |
| All backends show DOWN | GPU runners not reachable from LB | Verify LB can reach runner IPs. Check firewall. Ensure vLLM is actually running on runners |
| VIP not responding | Keepalived not running, or network issue | `systemctl status keepalived`. Check `ip addr` for VIP on the master LB |
| Split-brain (both LBs have VIP) | Network partition between LBs | Check Keepalived priority configuration. Ensure LBs can communicate on VRRP |

---

## 10. Phase H — Verification & Smoke Tests

### Commands

```bash
# Basic connectivity test
curl http://10.0.0.100:8000/v1/models

# Full inference test
curl http://10.0.0.100:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta-llama/Llama-3.1-70B-Instruct",
    "messages": [{"role": "user", "content": "Hello, how are you?"}],
    "max_tokens": 50
  }'

# Fleet health check
ansible-playbook -i inventory/hosts.yml playbooks/fleet-health-check.yml
```

### What to Verify

| Check | Expected Result | If Fails |
|---|---|---|
| `/v1/models` via VIP | JSON with all model IDs | LB or backend issue — check HAProxy stats page |
| `/v1/chat/completions` | Streaming response with generated text | Model not loaded, OOM, or CUDA error — check vLLM logs |
| `nvidia-smi` on each runner | All GPUs visible, temp < 80°C | Driver or hardware issue |
| `docker ps` on each runner | All vLLM containers UP (healthy) | Container crashed — check `docker logs` |
| `mountpoint /mnt/models` on each runner | Returns 0 (mounted) | NFS issue — check storage server |
| Grafana dashboards | Data flowing, no gaps | Monitoring agent or Prometheus issue |
| Alertmanager | Test alert fires and routes correctly | Webhook/email configuration issue |

### Performance Baseline Test

```bash
# Run from scripts directory
./scripts/vllm-benchmark.sh \
  --endpoint http://10.0.0.100:8000 \
  --model meta-llama/Llama-3.1-70B-Instruct \
  --concurrent 10 \
  --requests 100
```

Expected baseline (A100-80GB × 4, TP=4, Llama-3.1-70B):
- **Time-to-first-token (TTFT)**: < 500 ms
- **Throughput**: ~500–1000 tokens/sec
- **P99 latency**: < 5 seconds (for 256-token response)

---

## 11. Day-2 Operations

### Rolling Updates

**When**: Upgrading vLLM version (e.g., v0.8.3 → v0.8.4)

```bash
ansible-playbook -i inventory/hosts.yml playbooks/rolling-update-vllm.yml \
  -e new_vllm_image_tag=v0.8.4 --ask-vault-pass
```

**What happens for EACH runner (one at a time)**:
1. **Drain** — Tell load balancer to stop sending new requests to this runner
2. **Wait** — 30 seconds for in-flight requests to complete
3. **Pull** — Download new vLLM image
4. **Restart** — Recreate containers with new image
5. **Health check** — Wait up to 10 minutes for model to load and health check to pass
6. **Smoke test** — Hit `/v1/models` to verify the model is serving
7. **Re-enable** — Tell load balancer to start sending requests again
8. **Move to next runner**

**Why this order matters**: Steps 1-2 ensure zero dropped requests. Step 6 ensures the new version actually works before re-enabling traffic. If step 6 fails, the runner stays drained — other runners handle all traffic.

### Scaling Out (Add Runner)

```bash
# 1. Add new host to inventory/hosts.yml
# 2. Provision the new runner
ansible-playbook -i inventory/hosts.yml playbooks/scale-add-runner.yml \
  -l gpu-runner-04 --ask-vault-pass
```

### Scaling In (Remove Runner)

```bash
# Gracefully remove a runner from the fleet
ansible-playbook -i inventory/hosts.yml playbooks/scale-remove-runner.yml \
  -e target_runner=gpu-runner-02 --ask-vault-pass
```

---

## 12. Error Reference & Troubleshooting

### Quick Diagnosis Flowchart

```
Problem: vLLM not responding
│
├── Can you SSH to the runner?
│   ├── NO → Network issue / host down → Check IPMI, ping, SSH
│   └── YES ↓
│
├── Is nvidia-smi working?
│   ├── NO → Driver issue → Check dmesg, modprobe nvidia, possibly reboot
│   └── YES ↓
│
├── Is Docker running?
│   ├── NO → systemctl start docker → Check journalctl -u docker
│   └── YES ↓
│
├── Is the NFS mount active?
│   ├── NO → mount /mnt/models → Check storage server, network
│   └── YES ↓
│
├── Is the vLLM container running?
│   ├── NO → docker compose up -d → Check docker logs
│   └── YES ↓
│
├── Is the container healthy?
│   ├── NO → Check docker logs vllm-<name> → Look for CUDA OOM, model load errors
│   └── YES ↓
│
└── Is the load balancer routing to this runner?
    ├── NO → Check HAProxy stats → Re-enable backend
    └── YES → Problem is elsewhere (client-side, DNS, etc.)
```

### Top 10 Most Common Errors

| # | Error | Symptom | Root Cause | Resolution |
|---|---|---|---|---|
| 1 | **Driver/library version mismatch** | `nvidia-smi` fails after reboot | Kernel updated, DKMS didn't rebuild | `apt install --reinstall nvidia-driver-550` then reboot |
| 2 | **CUDA OOM** | Container exits immediately | Model too large for GPU memory | Reduce `gpu_memory_utilization`, reduce `max_model_len`, or use quantized model |
| 3 | **Stale NFS mount** | `ls /mnt/models` hangs forever | Storage server restarted | `umount -l /mnt/models && mount /mnt/models` |
| 4 | **Container name conflict** | `docker compose up` fails | Previous containers not cleaned | `docker compose down` then `docker compose up -d` |
| 5 | **Port conflict** | Container can't bind port | Another service on same port | Check `ss -tlnp | grep <port>`. Kill conflicting process |
| 6 | **Slow model loading** | Health check times out | NFS throughput bottleneck | Check NFS with `nfsstat`. Verify 10 GbE data network |
| 7 | **Fabric Manager not running** | Multi-GPU inference crashes | NVSwitch communication broken | `systemctl start nvidia-fabricmanager` |
| 8 | **GPU thermal throttling** | Inference suddenly slow | Temperature > 85°C | Check `nvidia-smi -q -d TEMPERATURE`. Fix airflow |
| 9 | **DNS resolution fails** | `apt update` fails, HF download fails | `/etc/resolv.conf` misconfigured | Fix nameservers. Check `systemd-resolved` |
| 10 | **Ansible vault password wrong** | All playbooks fail to start | Wrong password or missing vault file | Use `--ask-vault-pass` or set `ANSIBLE_VAULT_PASSWORD_FILE` |

### Log Locations

| Log | Location | What It Contains |
|---|---|---|
| vLLM container | `docker logs vllm-<model-name>` | Model loading, inference errors, CUDA errors |
| System | `/var/log/syslog` | Kernel messages, service starts/stops |
| NVIDIA driver | `dmesg | grep nvidia` | Driver load errors, GPU hardware events |
| Docker daemon | `journalctl -u docker` | Docker engine errors, image pull issues |
| NFS | `journalctl -t nfs-health` | Mount/unmount events, stale handle recovery |
| Audit | `/var/log/audit/audit.log` | Security events, privilege escalation |
| Model downloads | `/var/log/model-download-*.log` | HuggingFace download progress/errors |

---

## 13. Rollback Procedures

### vLLM Version Rollback

If a new vLLM version causes issues:

```bash
# Roll back to previous version
ansible-playbook -i inventory/hosts.yml playbooks/rolling-update-vllm.yml \
  -e new_vllm_image_tag=v0.8.3 --ask-vault-pass
```

Since images are tagged, the old image is still cached locally. Rollback is fast (no download needed).

### Model Rollback (ZFS Snapshot)

If a model update causes bad outputs:

```bash
# On storage server — list available snapshots
zfs list -t snapshot

# Rollback to yesterday's snapshot
zfs rollback models/data@20250115

# Remount on all runners (NFS sees changes automatically, but may need cache flush)
ansible gpu_runners -i inventory/hosts.yml -m command -a "umount -l /mnt/models && mount /mnt/models" --become
```

### Full Runner Rebuild

If a runner is in an unrecoverable state:

```bash
# Reinstall Ubuntu 22.04 (via PXE/USB/IPMI), then:
ansible-playbook -i inventory/hosts.yml playbooks/gpu-runner-full.yml \
  -l gpu-runner-01 --ask-vault-pass

ansible-playbook -i inventory/hosts.yml playbooks/deploy-vllm.yml \
  -l gpu-runner-01 --ask-vault-pass
```

Because runners are **stateless** (all models on NFS, all config in Ansible), a full rebuild takes ~30 minutes and produces an identical runner.

---

## Appendix: Complete Deployment Order

For a fresh deployment, run these in exact order:

| Order | Command | Duration | Can Parallelize? |
|---|---|---|---|
| 1 | Configure `hosts.yml` and `vault.yml` | 15 min (manual) | N/A |
| 2 | `ansible all -m ping` (pre-flight) | 30 sec | N/A |
| 3 | `playbooks/storage-server.yml` | 15–20 min | No — must complete before runners |
| 4 | `playbooks/model-download.yml` (per model) | 30–120 min each | Yes — can download multiple models in parallel |
| 5 | `playbooks/gpu-runner-full.yml` | 30–45 min | No — runs on all runners but sequentially within each |
| 6 | `playbooks/deploy-vllm.yml` | 10–15 min (rolling) | No — serial:1 by design |
| 7 | `playbooks/monitoring-stack.yml` | 5–10 min | Yes — independent of runners |
| 8 | `playbooks/load-balancer.yml` | 5–10 min | Yes — independent of monitoring |
| 9 | Verification & smoke tests | 5 min | N/A |

**Total**: ~2–4 hours for a 3-runner fleet (dominated by model download time)

---

*Document generated for vLLM Infrastructure v1.0.0*
