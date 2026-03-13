# vLLM Infrastructure Master Plan

## Architecture: Stateless GPU Runners + Centralized Model Storage

**Total Phases: 66 | Total Stages: 217**

---

## Overview Diagram

```
                    ┌──────────────────────────────────────────────────────────────┐
                    │                     CONTROL PLANE                            │
                    │  ┌─────────┐ ┌──────────┐ ┌────────┐ ┌──────────────────┐   │
                    │  │ Ansible │ │ Terraform│ │ GitLab │ │ Vault (Secrets)  │   │
                    │  │ Tower   │ │ State    │ │ CI/CD  │ │ PKI / Certs      │   │
                    │  └────┬────┘ └────┬─────┘ └───┬────┘ └────────┬─────────┘   │
                    └───────┼───────────┼───────────┼───────────────┼──────────────┘
                            │           │           │               │
          ┌─────────────────┼───────────┼───────────┼───────────────┼──────────────┐
          │                 │     MANAGEMENT NETWORK (10.0.0.0/24)  │              │
          │  ┌──────────────┴───────────┴───────────┴───────────────┴────────────┐ │
          │  │                        Management Switch                          │ │
          │  └──┬──────────┬──────────┬──────────┬──────────┬──────────┬────────┘ │
          │     │          │          │          │          │          │           │
          │  ┌──┴───┐  ┌──┴───┐  ┌──┴───┐  ┌──┴───┐  ┌──┴───┐  ┌──┴───────┐   │
          │  │ GPU  │  │ GPU  │  │ GPU  │  │ GPU  │  │ GPU  │  │ Model    │   │
          │  │Runner│  │Runner│  │Runner│  │Runner│  │Runner│  │ Storage  │   │
          │  │  01  │  │  02  │  │  03  │  │  04  │  │  05  │  │ Server   │   │
          │  │4×A100│  │4×A100│  │4×A100│  │8×H100│  │8×H100│  │ (NFS+HA) │   │
          │  └──┬───┘  └──┬───┘  └──┬───┘  └──┬───┘  └──┬───┘  └──┬───────┘   │
          │     │          │          │          │          │          │           │
          │  ┌──┴──────────┴──────────┴──────────┴──────────┴──────────┴────────┐ │
          │  │                    DATA NETWORK (10.1.0.0/24)                     │ │
          │  │                    25/100 Gbps NFS + GPU-GPU                      │ │
          │  └──────────────────────────────┬───────────────────────────────────┘ │
          └─────────────────────────────────┼─────────────────────────────────────┘
                                            │
          ┌─────────────────────────────────┼─────────────────────────────────────┐
          │  ┌──────────────────────────────┴───────────────────────────────────┐ │
          │  │                    SERVICE MESH / LB TIER                        │ │
          │  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────────────┐   │ │
          │  │  │ HAProxy  │  │ API GW   │  │ Rate     │  │ TLS Termination│   │ │
          │  │  │ (L4 LB)  │  │ (Auth)   │  │ Limiter  │  │ (Let's Encrypt)│   │ │
          │  │  └──────────┘  └──────────┘  └──────────┘  └────────────────┘   │ │
          │  └──────────────────────────────┬───────────────────────────────────┘ │
          │                                 │                                     │
          │  ┌──────────────────────────────┴───────────────────────────────────┐ │
          │  │                    OBSERVABILITY STACK                           │ │
          │  │  ┌────────────┐ ┌─────────┐ ┌───────┐ ┌──────────┐ ┌────────┐  │ │
          │  │  │ Prometheus │ │ Grafana │ │ Loki  │ │ Alertmgr │ │ Jaeger │  │ │
          │  │  └────────────┘ └─────────┘ └───────┘ └──────────┘ └────────┘  │ │
          │  └─────────────────────────────────────────────────────────────────┘ │
          └─────────────────────────────────────────────────────────────────────┘
```

---

# PHASE 01: PROJECT BOOTSTRAP & REPOSITORY STRUCTURE
**Stages 1–4**

| Stage | Name | Description |
|-------|------|-------------|
| 1 | Repository initialization | Git repo, branch strategy, .gitignore, pre-commit hooks, LICENSE |
| 2 | Directory structure | Create canonical folder layout for all 66 phases |
| 3 | Documentation framework | README templates, ADR (Architecture Decision Records), runbook templates |
| 4 | Version pinning manifest | Lock all tool versions: Ansible, Terraform, Docker, CUDA, driver, vLLM, Python |

---

# PHASE 02: INFRASTRUCTURE INVENTORY & ASSET MANAGEMENT
**Stages 5–8**

| Stage | Name | Description |
|-------|------|-------------|
| 5 | Hardware inventory | Document every server: hostname, IP, MAC, GPU type/count, RAM, disk, NIC |
| 6 | Network topology mapping | VLAN assignments, subnet plan, switch port mapping, cable labeling |
| 7 | Ansible inventory creation | Static inventory with host groups: gpu_runners, storage_servers, monitoring, lb |
| 8 | Asset tagging & CMDB | Tag physical assets, create configuration management database entries |

---

# PHASE 03: NETWORK FOUNDATION
**Stages 9–14**

| Stage | Name | Description |
|-------|------|-------------|
| 9 | VLAN configuration | Separate VLANs: management (VLAN 10), data/NFS (VLAN 20), client (VLAN 30), IPMI (VLAN 99) |
| 10 | Switch configuration | L2/L3 switch configs, jumbo frames (MTU 9000) on data network, spanning tree |
| 11 | DNS setup | Internal DNS zone (e.g., `gpu.internal`), A/CNAME records for all hosts, reverse DNS |
| 12 | NTP synchronization | Chrony/NTP server config, all nodes sync to same source, drift monitoring |
| 13 | DHCP reservation | Static DHCP leases for all servers on management network, PXE boot entries |
| 14 | Firewall baseline rules | iptables/nftables base ruleset: deny all, allow SSH from bastion, allow NFS on data VLAN |

---

# PHASE 04: OPERATING SYSTEM PROVISIONING
**Stages 15–21**

| Stage | Name | Description |
|-------|------|-------------|
| 15 | Ubuntu 22.04 base image | Create preseed/autoinstall config for unattended Ubuntu 22.04.x LTS install |
| 16 | PXE boot infrastructure | TFTP server, PXE menu, network boot for bare-metal provisioning |
| 17 | Kernel selection & pinning | Pin kernel version compatible with NVIDIA driver (e.g., 5.15.x HWE), disable auto-update |
| 18 | Partition layout | Standardized partitioning: 512MB /boot/efi, 50GB /, 16GB swap, remainder /data |
| 19 | Base package installation | Install essential packages: build-essential, curl, wget, git, jq, tmux, htop, iotop, dstat |
| 20 | User & group setup | Create service accounts (vllm-user, node-exporter), sudo rules, SSH key deployment |
| 21 | Locale & timezone | Set UTC timezone, en_US.UTF-8 locale, consistent across all nodes |

---

# PHASE 05: OS HARDENING & SECURITY BASELINE
**Stages 22–30**

| Stage | Name | Description |
|-------|------|-------------|
| 22 | SSH hardening | Disable root login, password auth off, key-only, port 22 or custom, fail2ban |
| 23 | Kernel security parameters | sysctl hardening: disable IP forwarding (non-routers), SYN cookies, ASLR, restrict dmesg |
| 24 | AppArmor profiles | Enable AppArmor, create profiles for Docker daemon, NVIDIA processes |
| 25 | Automatic security updates | Configure unattended-upgrades for security patches only, exclude kernel/nvidia packages |
| 26 | Audit framework | Install & configure auditd: file access, privilege escalation, network connections |
| 27 | Disk encryption (optional) | LUKS encryption for /data if compliance requires, key escrow strategy |
| 28 | USB & peripheral lockdown | Disable USB storage kernel modules, restrict physical port access |
| 29 | Banner & MOTD | Legal login banner, system info MOTD (hostname, GPU count, IP, vLLM version) |
| 30 | CIS benchmark scan | Run CIS Ubuntu 22.04 benchmark, remediate findings, document exceptions |

---

# PHASE 06: NVIDIA DRIVER & CUDA INSTALLATION
**Stages 31–38**

| Stage | Name | Description |
|-------|------|-------------|
| 31 | Blacklist nouveau driver | Blacklist nouveau, regenerate initramfs, reboot |
| 32 | NVIDIA driver installation | Install pinned driver version (e.g., 550.xx) from NVIDIA repo, NOT Ubuntu default |
| 33 | NVIDIA driver verification | Validate nvidia-smi output, check all GPUs visible, ECC status, driver version match |
| 34 | CUDA toolkit installation | Install CUDA 12.4 toolkit, set PATH and LD_LIBRARY_PATH in /etc/profile.d/ |
| 35 | cuDNN installation | Install cuDNN matching CUDA version, verify with sample test |
| 36 | NVIDIA persistence daemon | Enable nvidia-persistenced, reduce GPU initialization latency |
| 37 | NVIDIA fabric manager | Install & enable for NVSwitch-based systems (HGX, DGX), skip for consumer GPUs |
| 38 | GPU topology verification | Run nvidia-smi topo -m, document NVLink/NVSwitch topology, validate expected interconnect |

---

# PHASE 07: NVIDIA GPU CONFIGURATION & TUNING
**Stages 39–47**

| Stage | Name | Description |
|-------|------|-------------|
| 39 | GPU clock configuration | Set application clocks for inference workload, lock GPU clocks if needed |
| 40 | Power limit configuration | Set per-GPU power limits via nvidia-smi -pl, persist via systemd unit |
| 41 | ECC memory configuration | Verify ECC enabled (datacenter GPUs), check for memory errors, set thresholds |
| 42 | GPU compute mode | Set to DEFAULT or EXCLUSIVE_PROCESS depending on multi-tenant strategy |
| 43 | MIG configuration (optional) | For A100/H100: configure MIG profiles if partitioning GPUs for multiple models |
| 44 | PCIe settings | Verify PCIe Gen4/Gen5 link speed and width, check for degraded links |
| 45 | NUMA affinity documentation | Map GPU-to-NUMA-node affinity, document for CPU pinning in Docker |
| 46 | GPU health check script | Create automated GPU health validator: temp, power, ECC, clocks, PCIe |
| 47 | Thermal management | Configure fan curves (if applicable), set thermal throttle thresholds, alert on high temp |

---

# PHASE 08: DOCKER ENGINE INSTALLATION
**Stages 48–54**

| Stage | Name | Description |
|-------|------|-------------|
| 48 | Docker repository setup | Add Docker official GPG key and apt repository, pin Docker version |
| 49 | Docker engine installation | Install docker-ce, docker-ce-cli, containerd.io, docker-compose-plugin |
| 50 | Docker daemon configuration | Configure /etc/docker/daemon.json: log driver, storage driver, default runtime |
| 51 | Docker storage backend | Configure overlay2, set data-root to /data/docker if separate disk, set max log size |
| 52 | Docker network setup | Create custom bridge networks, configure DNS, set default address pools |
| 53 | Docker user permissions | Add vllm-user to docker group, configure rootless mode if required |
| 54 | Docker systemd integration | Enable Docker service, configure restart policy, set resource limits in systemd drop-in |

---

# PHASE 09: NVIDIA CONTAINER TOOLKIT
**Stages 55–61**

| Stage | Name | Description |
|-------|------|-------------|
| 55 | NVIDIA Container Toolkit repo | Add nvidia-container-toolkit GPG key and apt repository |
| 56 | Toolkit installation | Install nvidia-container-toolkit package, pin version |
| 57 | Docker runtime configuration | Run nvidia-ctk runtime configure --runtime=docker, restart Docker daemon |
| 58 | Default GPU runtime | Set nvidia as default runtime in daemon.json (optional, depends on mixed workloads) |
| 59 | Container GPU verification | docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi |
| 60 | CDI (Container Device Interface) | Configure CDI for fine-grained GPU device selection in containers |
| 61 | GPU isolation testing | Test --gpus '"device=0,1"' syntax, verify isolation between containers |

---

# PHASE 10: STORAGE SERVER SETUP (NFS)
**Stages 62–70**

| Stage | Name | Description |
|-------|------|-------------|
| 62 | Storage server OS provisioning | Ubuntu 22.04 on storage server(s), same hardening as GPU runners |
| 63 | Storage disk configuration | RAID setup (RAID-6 or ZFS raidz2), filesystem choice (XFS or ZFS), mount at /srv/models |
| 64 | NFS server installation | Install nfs-kernel-server, configure /etc/exports with GPU runner subnet |
| 65 | NFS export tuning | Set async/sync, no_subtree_check, crossmnt, configure rsize/wsize 1048576 |
| 66 | NFS security | Restrict exports to data VLAN subnet only, no_root_squash only if needed, Kerberos optional |
| 67 | NFS performance tuning | Tune NFS threads (RPCNFSDCOUNT=32+), enable NFSv4.1+ session trunking |
| 68 | Storage high availability | DRBD or GlusterFS replication between primary and secondary storage server |
| 69 | Storage monitoring | Monitor disk health (SMART), usage alerts at 70/80/90%, NFS connection count |
| 70 | Storage backup strategy | Nightly ZFS snapshots, weekly offsite backup of model registry metadata |

---

# PHASE 11: NFS CLIENT CONFIGURATION (GPU RUNNERS)
**Stages 71–76**

| Stage | Name | Description |
|-------|------|-------------|
| 71 | NFS client installation | Install nfs-common on all GPU runners |
| 72 | Mount point creation | Create /mnt/models directory with correct ownership/permissions |
| 73 | fstab configuration | Add NFS mount entry: ro,hard,intr,nfsvers=4.1,rsize=1048576,wsize=1048576,timeo=600 |
| 74 | Auto-mount validation | Reboot test: verify NFS auto-mounts, vLLM can read model files |
| 75 | Failover mount config | Configure secondary NFS server in mount options (replicas=) or autofs |
| 76 | Mount health monitoring | Create systemd timer to check mount health, alert on stale mounts, auto-remount |

---

# PHASE 12: MODEL REGISTRY & LIFECYCLE MANAGEMENT
**Stages 77–85**

| Stage | Name | Description |
|-------|------|-------------|
| 77 | Model directory structure | Standardize: /srv/models/{provider}/{model-name}/{version}/ |
| 78 | Model download automation | Script for huggingface-cli download with checksum validation, resume support |
| 79 | Model integrity verification | SHA256 checksums for all model files, verify after download and periodically |
| 80 | Model version management | Git-based or metadata-file-based versioning, track which version is "active" |
| 81 | Model catalog/registry | JSON/YAML catalog listing all available models, sizes, quantization, compatible GPU configs |
| 82 | Model conversion pipeline | Scripts for format conversion: safetensors, GPTQ, AWQ, FP8 quantization |
| 83 | Model cleanup policy | Automated cleanup of old versions, keep N versions, archive to cold storage |
| 84 | Model access control | Per-model directory permissions, track which runners serve which models |
| 85 | Model pre-warming | Script to load model into page cache on NFS server before directing traffic |

---

# PHASE 13: DOCKER IMAGE MANAGEMENT
**Stages 86–93**

| Stage | Name | Description |
|-------|------|-------------|
| 86 | Private Docker registry | Deploy Harbor or GitLab Container Registry for internal image hosting |
| 87 | Base image creation | Custom vLLM base image with pinned versions, security patches, custom entrypoints |
| 88 | Image build pipeline | CI/CD pipeline: build, scan, tag, push to registry on every change |
| 89 | Image vulnerability scanning | Trivy/Grype scanning in CI, block deployment of images with critical CVEs |
| 90 | Image signing | Cosign/Notary for image signature verification, enforce in runtime policy |
| 91 | Image tagging strategy | Semantic versioning + git SHA: vllm-server:1.2.3-abc1234, never deploy :latest |
| 92 | Image size optimization | Multi-stage builds, remove build dependencies, minimize layer count |
| 93 | Image pull policy | Configure pre-pull on GPU runners via systemd timer, reduce cold-start time |

---

# PHASE 14: vLLM CONTAINER CONFIGURATION
**Stages 94–104**

| Stage | Name | Description |
|-------|------|-------------|
| 94 | Docker Compose template | Parameterized compose file with environment variable substitution |
| 95 | Environment file management | .env file per runner with: MODEL_NAME, TP_SIZE, GPU_IDS, PORT, MAX_MODEL_LEN |
| 96 | Container resource limits | CPU limits, memory limits, shared memory size (--ipc=host or --shm-size) |
| 97 | GPU device assignment | Map specific GPUs to containers: device_ids: ['0','1','2','3'] |
| 98 | Volume mount configuration | Model mount (ro), HuggingFace cache mount, log mount, config mount |
| 99 | Network configuration | Host networking vs bridge, port mapping, container DNS resolution |
| 100 | Health check definition | Docker HEALTHCHECK: curl http://localhost:8000/health with interval/timeout/retries |
| 101 | Restart policy | restart: unless-stopped, with backoff via systemd or Docker restart policy |
| 102 | Log configuration | JSON file log driver, max-size: 100m, max-file: 5, structured logging |
| 103 | Init container pattern | Sidecar/init script to verify GPU health + NFS mount before starting vLLM |
| 104 | Graceful shutdown | Configure SIGTERM handling, drain in-flight requests, timeout before SIGKILL |

---

# PHASE 15: vLLM ENGINE CONFIGURATION — SINGLE GPU
**Stages 105–110**

| Stage | Name | Description |
|-------|------|-------------|
| 105 | Basic single-GPU config | --model, --host, --port, --dtype auto, --max-model-len |
| 106 | Memory utilization tuning | --gpu-memory-utilization 0.90 (tune per model/GPU), measure actual VRAM usage |
| 107 | Tokenizer configuration | --tokenizer (if separate), --tokenizer-mode auto, trust-remote-code if needed |
| 108 | Request handling | --max-num-seqs 256, --max-num-batched-tokens, --max-paddings |
| 109 | Sampling defaults | Default temperature, top-p, top-k, repetition penalty via server config |
| 110 | API compatibility | --served-model-name for OpenAI-compatible endpoint naming, --chat-template |

---

# PHASE 16: vLLM ENGINE CONFIGURATION — MULTI-GPU (TENSOR PARALLELISM)
**Stages 111–117**

| Stage | Name | Description |
|-------|------|-------------|
| 111 | Tensor parallel sizing | --tensor-parallel-size N, must divide attention heads evenly |
| 112 | NVLink topology validation | Verify NVLink connectivity between TP GPU group, benchmark inter-GPU bandwidth |
| 113 | CUDA_VISIBLE_DEVICES | Set explicit GPU ordering matching physical topology |
| 114 | NCCL environment tuning | NCCL_IB_DISABLE, NCCL_P2P_DISABLE, NCCL_SOCKET_IFNAME for network optimization |
| 115 | Distributed backend selection | --distributed-executor-backend mp (multiprocessing) vs ray |
| 116 | TP benchmark | Measure TTFT and TPS at TP=1,2,4,8, find optimal TP for each model |
| 117 | TP + model compatibility matrix | Document which models work at which TP sizes on which GPU configs |

---

# PHASE 17: vLLM ENGINE CONFIGURATION — PIPELINE PARALLELISM
**Stages 118–122**

| Stage | Name | Description |
|-------|------|-------------|
| 118 | Pipeline parallel sizing | --pipeline-parallel-size N, for non-NVLink topologies |
| 119 | Combined TP+PP | --tensor-parallel-size 2 --pipeline-parallel-size 2 for 4-GPU setups without full NVLink |
| 120 | PP layer distribution | Verify even layer distribution, monitor per-GPU memory usage for imbalances |
| 121 | PP latency analysis | Measure pipeline bubble overhead, compare with pure TP |
| 122 | Multi-node PP (Ray) | Ray cluster setup for models exceeding single-node GPU memory |

---

# PHASE 18: vLLM ADVANCED FEATURES
**Stages 123–132**

| Stage | Name | Description |
|-------|------|-------------|
| 123 | Quantization — AWQ | --quantization awq, download AWQ-quantized models, benchmark accuracy vs speed |
| 124 | Quantization — GPTQ | --quantization gptq, verify compatibility, measure quality regression |
| 125 | Quantization — FP8 | --quantization fp8 for H100+, near-lossless compression |
| 126 | Prefix caching | --enable-prefix-caching for repeated system prompts, measure cache hit rate |
| 127 | Chunked prefill | --enable-chunked-prefill for long-context workloads, tune chunk size |
| 128 | Speculative decoding | --speculative-model, --num-speculative-tokens, benchmark latency improvement |
| 129 | LoRA adapter serving | --enable-lora, --lora-modules, multi-adapter hot-swapping |
| 130 | Guided decoding | JSON schema / regex constrained generation configuration |
| 131 | Multi-step scheduling | --num-scheduler-steps 8, reduce scheduling overhead |
| 132 | Sleep mode | --enable-sleep-mode for idle GPU memory release during low-traffic periods |

---

# PHASE 19: API GATEWAY & LOAD BALANCING
**Stages 133–140**

| Stage | Name | Description |
|-------|------|-------------|
| 133 | HAProxy installation | Install HAProxy on dedicated LB nodes, configure for TCP (L4) load balancing |
| 134 | Backend health checks | HAProxy health check against /health endpoint, remove unhealthy backends |
| 135 | Load balancing algorithm | Least-connections for streaming, round-robin for batch, weighted by GPU capacity |
| 136 | Session persistence | Sticky sessions if needed for multi-turn conversations, cookie-based affinity |
| 137 | TLS termination | Let's Encrypt or internal CA certificates, TLS 1.3, HSTS headers |
| 138 | Rate limiting | Per-client rate limits: requests/min, tokens/min, concurrent connections |
| 139 | API authentication | API key validation, JWT token verification, per-key usage tracking |
| 140 | Request routing | Route by model name: /v1/chat/completions → appropriate vLLM backend pool |

---

# PHASE 20: REVERSE PROXY & EDGE
**Stages 141–145**

| Stage | Name | Description |
|-------|------|-------------|
| 141 | Nginx reverse proxy | Frontend Nginx for HTTP/2, WebSocket upgrade (streaming), request buffering |
| 142 | CORS configuration | Cross-origin resource sharing headers for web clients |
| 143 | Request/response logging | Log request metadata (model, tokens, latency) without logging prompt content |
| 144 | DDoS mitigation | Connection limits, slowloris protection, IP-based blocking |
| 145 | CDN integration (optional) | CloudFlare or internal CDN for static assets, API documentation hosting |

---

# PHASE 21: PROMETHEUS MONITORING
**Stages 146–152**

| Stage | Name | Description |
|-------|------|-------------|
| 146 | Prometheus server setup | Install Prometheus, configure retention (30d), storage sizing |
| 147 | Node exporter | Deploy node_exporter on all hosts: CPU, memory, disk, network metrics |
| 148 | NVIDIA GPU exporter | Deploy dcgm-exporter or nvidia-gpu-exporter for GPU metrics |
| 149 | vLLM metrics scraping | Scrape vLLM /metrics endpoint: request latency, token throughput, queue depth |
| 150 | NFS metrics | Monitor NFS client stats: operations/sec, latency, retransmits, stale handles |
| 151 | Docker metrics | cAdvisor or Docker metrics endpoint for container resource usage |
| 152 | Prometheus service discovery | File-based or DNS-based SD for dynamic GPU runner fleet |

---

# PHASE 22: GRAFANA DASHBOARDS
**Stages 153–158**

| Stage | Name | Description |
|-------|------|-------------|
| 153 | Grafana installation | Install Grafana, configure Prometheus datasource, LDAP/SSO authentication |
| 154 | GPU fleet overview dashboard | All GPUs: utilization, temperature, power, memory, ECC errors, clock speeds |
| 155 | vLLM performance dashboard | Per-instance: requests/sec, tokens/sec, TTFT, TBT, queue depth, cache hit rate |
| 156 | Model serving dashboard | Per-model: request volume, latency percentiles, error rates, active instances |
| 157 | Infrastructure dashboard | NFS throughput, network utilization, disk IOPS, system load, Docker stats |
| 158 | Capacity planning dashboard | GPU utilization trends, model growth projections, headroom analysis |

---

# PHASE 23: ALERTING
**Stages 159–165**

| Stage | Name | Description |
|-------|------|-------------|
| 159 | Alertmanager setup | Install Alertmanager, configure routes, silences, inhibition rules |
| 160 | GPU alerts | Alert on: GPU temp >85°C, utilization <10% (idle waste), ECC errors, fallen off bus |
| 161 | vLLM alerts | Alert on: p99 latency >5s, error rate >1%, OOM kills, health check failures |
| 162 | Storage alerts | Alert on: disk usage >80%, NFS mount stale, SMART errors, RAID degraded |
| 163 | System alerts | Alert on: CPU >90% sustained, memory >85%, swap usage, disk I/O saturation |
| 164 | Notification channels | Slack, PagerDuty, email, webhook integrations for alert routing |
| 165 | Alert runbook links | Every alert links to a runbook with diagnosis steps and resolution procedures |

---

# PHASE 24: LOG AGGREGATION
**Stages 166–171**

| Stage | Name | Description |
|-------|------|-------------|
| 166 | Loki installation | Deploy Grafana Loki for log aggregation, configure retention and storage |
| 167 | Promtail agents | Deploy Promtail on all nodes, scrape Docker logs, system logs, vLLM logs |
| 168 | Log labeling | Label logs by: host, service, model, gpu_id, request_id for filtering |
| 169 | vLLM request logging | Log request metadata: model, prompt_tokens, completion_tokens, latency, status |
| 170 | Log-based alerting | Loki alerting rules for error patterns: CUDA OOM, NFS timeout, model load failure |
| 171 | Log retention policy | 7 days hot storage, 30 days warm, archive critical events to object storage |

---

# PHASE 25: DISTRIBUTED TRACING
**Stages 172–175**

| Stage | Name | Description |
|-------|------|-------------|
| 172 | Jaeger/Tempo setup | Deploy distributed tracing backend for request flow visualization |
| 173 | Trace instrumentation | Add OpenTelemetry SDK to API gateway, propagate trace context to vLLM |
| 174 | Trace-based analysis | Identify bottlenecks: tokenization, prefill, decode, network, queue wait |
| 175 | Trace sampling policy | Head-based sampling at 1% for normal traffic, 100% for errors |

---

# PHASE 26: SECRETS MANAGEMENT
**Stages 176–179**

| Stage | Name | Description |
|-------|------|-------------|
| 176 | HashiCorp Vault setup | Deploy Vault for centralized secrets: API keys, HF tokens, TLS certs |
| 177 | Secret injection | Docker secrets or Vault Agent sidecar to inject secrets into containers |
| 178 | Secret rotation | Automated rotation of API keys, TLS certificates, database passwords |
| 179 | Secret audit logging | Log all secret access: who, when, which secret, from where |

---

# PHASE 27: TLS & CERTIFICATE MANAGEMENT
**Stages 180–183**

| Stage | Name | Description |
|-------|------|-------------|
| 180 | Internal CA setup | Create internal Certificate Authority for service-to-service TLS |
| 181 | Certificate issuance | Issue TLS certs for: API gateway, Grafana, Prometheus, Vault, NFS (optional) |
| 182 | Certificate auto-renewal | Certbot or step-ca for automated certificate renewal |
| 183 | mTLS (optional) | Mutual TLS between API gateway and vLLM backends for zero-trust |

---

# PHASE 28: RBAC & ACCESS CONTROL
**Stages 184–187**

| Stage | Name | Description |
|-------|------|-------------|
| 184 | LDAP/SSO integration | Integrate Grafana, Vault, registry with LDAP/SAML/OIDC |
| 185 | Role definitions | Define roles: admin, operator, developer, read-only, per-model access |
| 186 | API key management | Per-client API keys with quotas, expiry, revocation capability |
| 187 | Audit trail | Log all administrative actions: config changes, deployments, access |

---

# PHASE 29: CI/CD PIPELINE
**Stages 188–193**

| Stage | Name | Description |
|-------|------|-------------|
| 188 | GitLab CI/CD setup | .gitlab-ci.yml for automated build, test, deploy pipeline |
| 189 | Infrastructure testing | Ansible lint, Terraform validate, Docker build test, compose config validation |
| 190 | Integration testing | Automated vLLM smoke test: start container, send request, validate response |
| 191 | Performance regression test | Benchmark suite: measure TTFT, TPS at standard load, compare with baseline |
| 192 | Staging environment | Reduced-scale staging with 1 GPU runner for pre-production validation |
| 193 | Deployment automation | Ansible playbook for rolling deploy: drain → update → verify → enable per runner |

---

# PHASE 30: DEPLOYMENT STRATEGIES
**Stages 194–198**

| Stage | Name | Description |
|-------|------|-------------|
| 194 | Blue-green deployment | Two pools of runners, switch LB between blue/green for zero-downtime updates |
| 195 | Canary deployment | Route 5% traffic to new version, monitor metrics, promote or rollback |
| 196 | Rolling update | Update one runner at a time, LB drains connections before update |
| 197 | Rollback procedure | One-command rollback: previous image tag, previous config, verified runbook |
| 198 | Model hot-swap | Update model path in config, restart vLLM container, LB handles drain/fill |

---

# PHASE 31: POWER MANAGEMENT
**Stages 199–204**

| Stage | Name | Description |
|-------|------|-------------|
| 199 | GPU power profiling | Benchmark each GPU at different power limits, document perf/watt curve |
| 200 | Power limit systemd service | Persistent nvidia-smi -pl via systemd oneshot, survives reboots |
| 201 | Dynamic power scaling | Script to adjust power limits based on time-of-day or load (peak/off-peak) |
| 202 | Per-container power budget | Assign GPU power budgets per workload priority class |
| 203 | Total facility power monitoring | Monitor PDU/UPS power draw, correlate with GPU fleet utilization |
| 204 | Power alerting | Alert when total power exceeds facility budget, auto-throttle lowest priority |

---

# PHASE 32: PERFORMANCE TUNING & BENCHMARKING
**Stages 205–209**

| Stage | Name | Description |
|-------|------|-------------|
| 205 | Benchmark framework | Standard benchmark suite: varying concurrency, prompt lengths, models |
| 206 | TTFT optimization | Tune chunked prefill, prefix caching, measure time-to-first-token |
| 207 | Throughput optimization | Tune max-num-seqs, max-num-batched-tokens, num-scheduler-steps |
| 208 | Memory optimization | Profile VRAM usage, tune gpu-memory-utilization, measure KV cache size |
| 209 | A/B performance testing | Compare configurations side-by-side under identical load |

---

# PHASE 33: DISASTER RECOVERY
**Stages 210–213**

| Stage | Name | Description |
|-------|------|-------------|
| 210 | DR runbook | Step-by-step recovery for every failure mode: GPU, storage, network, full site |
| 211 | Storage failover test | Quarterly test: fail primary NFS, verify runners switch to secondary |
| 212 | Runner rebuild automation | One-command full runner rebuild from scratch in <30 minutes |
| 213 | Configuration backup | Git-based backup of all configs, Vault backup, Prometheus TSDB snapshots |

---

# PHASE 34: CAPACITY PLANNING
**Stages 214–217**

| Stage | Name | Description |
|-------|------|-------------|
| 214 | Demand forecasting | Track request growth trends, model size trends, predict capacity needs |
| 215 | GPU procurement planning | Lead time tracking, vendor relationships, budget forecasting |
| 216 | Scaling playbook | Documented procedure: add new runner to fleet in <2 hours |
| 217 | Cost optimization review | Monthly review: GPU utilization, idle time, model consolidation opportunities |

---

# Remaining Phases (35–66): Cross-Cutting Concerns

| Phase | Name | Key Focus |
|-------|------|-----------|
| 35 | Multi-model serving | Multiple models per runner, routing by model name |
| 36 | Model A/B testing | Traffic splitting between model versions |
| 37 | Batch inference pipeline | Offline batch processing jobs for bulk requests |
| 38 | Embedding model serving | Separate embedding model instances, vector API |
| 39 | Vision model support | Multi-modal model configuration (LLaVA, etc.) |
| 40 | Function calling setup | Tool-use / function-calling model configuration |
| 41 | Structured output | JSON mode, guided decoding configuration |
| 42 | Streaming optimization | SSE streaming tuning, chunk size, buffering |
| 43 | Client SDK & libraries | Python/JS/Go client libraries for internal consumers |
| 44 | API versioning | /v1/, /v2/ endpoint versioning strategy |
| 45 | Request queuing | Redis-based request queue for burst handling |
| 46 | Priority queuing | High/low priority request lanes, SLA-based routing |
| 47 | Token budgeting | Per-client token quotas, usage tracking, billing integration |
| 48 | Usage analytics | Track per-client, per-model usage for chargeback |
| 49 | Compliance & data residency | Ensure prompts/completions stay in-region, audit logging |
| 50 | PII detection | Scan requests/responses for PII, mask or reject |
| 51 | Content filtering | Safety filters on input/output, moderation API integration |
| 52 | Prompt injection defense | Input validation, system prompt protection |
| 53 | Network segmentation | Micro-segmentation between tiers, zero-trust networking |
| 54 | Vulnerability management | Regular patching cadence, CVE tracking, risk acceptance process |
| 55 | Penetration testing | Annual pentest of API gateway, internal network, container escapes |
| 56 | Incident response plan | Playbooks for: data breach, GPU failure, service outage, model poisoning |
| 57 | Change management | RFC process for infrastructure changes, approval workflow |
| 58 | Documentation | Architecture docs, operational runbooks, API documentation |
| 59 | Knowledge base | Internal wiki with troubleshooting guides, FAQs, decision records |
| 60 | Team training | Training program for operators: GPU debugging, vLLM tuning, Docker ops |
| 61 | On-call rotation | PagerDuty rotation, escalation paths, handoff procedures |
| 62 | SLA/SLO definition | Define SLOs: p99 latency <3s, availability 99.9%, error rate <0.1% |
| 63 | Chaos engineering | Fault injection testing: kill GPUs, fail NFS, network partition |
| 64 | Multi-region expansion | Playbook for adding a second site/region |
| 65 | Kubernetes migration path | Plan for eventual K8s migration if fleet grows beyond Ansible+Docker |
| 66 | Continuous improvement | Monthly retros, metric-driven optimization, technology radar |

---

# Implementation Priority

## Wave 1 — Minimum Viable Infrastructure (Phases 1–14)
Get one GPU runner serving one model from NFS storage.

## Wave 2 — Production Hardening (Phases 15–25)
Multi-GPU, monitoring, alerting, load balancing, logs.

## Wave 3 — Security & Compliance (Phases 26–30)
Secrets, TLS, RBAC, CI/CD, deployment strategies.

## Wave 4 — Optimization & Scale (Phases 31–34)
Power management, performance tuning, DR, capacity planning.

## Wave 5 — Advanced Capabilities (Phases 35–66)
Multi-model, structured output, compliance, chaos engineering, training.
