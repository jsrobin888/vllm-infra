# ADR-001: Separate Storage from GPU Compute

**Date:** 2024-08-01
**Status:** Accepted
**Deciders:** Infrastructure Team

## Context

We need to serve multiple LLM models across a fleet of GPU servers. Models range from 15 GB to 130+ GB. Two architectural options were considered:

1. **Co-located storage**: Each GPU runner stores its own model copies
2. **Separated storage**: Central NFS server stores models, GPU runners mount read-only

## Decision

We chose **separated NFS storage** with read-only mounts on GPU runners.

## Rationale

| Factor | Co-located | Separated (NFS) |
|--------|-----------|-----------------|
| Storage cost | High (N copies × M models) | Low (1 copy per model) |
| Model update | Update N servers | Update 1 server |
| GPU runner state | Stateful | Stateless |
| Recovery time | Long (re-download model) | Fast (remount NFS) |
| Consistency | Risk of version drift | Single source of truth |
| Network dependency | None | NFS availability required |
| Loading speed | Local NVMe (fast) | NFS over network (slightly slower) |

## Consequences

- **Positive:** Stateless GPU runners, easy scaling, single model management point
- **Negative:** NFS becomes a dependency; must be highly available
- **Mitigation:** Secondary NFS server with rsync replication, auto-failover

---

# ADR-002: ZFS on NFS Storage Server

**Date:** 2024-08-01
**Status:** Accepted

## Context

Storage backend needs to handle large sequential reads (model loading) with data integrity guarantees.

## Decision

Use ZFS with raidz2 on NVMe drives for the NFS-exported model storage.

## Rationale

- **raidz2**: Tolerates 2 disk failures (critical for production)
- **Compression (lz4)**: Reduces storage footprint with minimal CPU overhead
- **1M recordsize**: Optimized for large sequential reads (model files)
- **Snapshots**: Point-in-time recovery, cheap to create
- **Scrub**: Regular integrity verification

## Consequences

- Requires ZFS knowledge for maintenance
- Memory-hungry (ARC cache uses available RAM — beneficial for caching model reads)
- Snapshot retention policy needed (14 days implemented)

---

# ADR-003: Docker Compose over Kubernetes

**Date:** 2024-08-01
**Status:** Accepted

## Context

Needed container orchestration for vLLM deployments. Options: bare Docker, Docker Compose, Kubernetes.

## Decision

Docker Compose managed by Ansible, not Kubernetes.

## Rationale

- Fleet size is small (3-10 GPU runners), not 100s
- Kubernetes adds significant complexity for GPU workloads
- Docker Compose with Ansible provides sufficient orchestration
- GPU device assignment is explicit and predictable
- Rolling updates achievable with Ansible serial deployment
- No need for Kubernetes auto-scaling (GPU nodes are fixed hardware)

## Consequences

- Simpler to operate and debug
- No auto-healing (rely on Docker restart policies + monitoring alerts)
- No built-in service mesh (HAProxy provides load balancing)
- May revisit if fleet grows beyond 20 nodes

---

# ADR-004: Ansible for Configuration Management

**Date:** 2024-08-01
**Status:** Accepted

## Context

Need reproducible server provisioning and deployment across heterogeneous nodes (GPU runners, storage, monitoring, LB).

## Decision

Ansible with role-based playbooks, YAML inventory, and Vault for secrets.

## Rationale

- Agentless: no daemon needed on target servers
- Idempotent: safe to re-run
- Role-based: modular, reusable components
- YAML inventory: clear node classification with per-host variables
- Vault: encrypted secrets in git
- Strong community support for NVIDIA, Docker, NFS modules

## Consequences

- SSH-based: slightly slower than agent-based tools at scale
- State is on target hosts (no central state database)
- Sufficient for our fleet size

---

# ADR-005: Prometheus + Grafana for Observability

**Date:** 2024-08-01
**Status:** Accepted

## Context

Need monitoring for GPU health, vLLM performance, infrastructure metrics, and alerting.

## Decision

Prometheus (metrics) + Grafana (dashboards) + Loki (logs) + Alertmanager (alerts).

## Rationale

- DCGM Exporter provides comprehensive NVIDIA GPU metrics natively in Prometheus format
- vLLM exposes Prometheus-format metrics on /metrics endpoint
- node_exporter is the standard for Linux system metrics
- Grafana provides rich visualization with templating
- Loki integrates with Grafana for correlated log/metric analysis
- Alertmanager supports Slack, PagerDuty, and complex routing

## Consequences

- Requires dedicated monitoring server (4+ CPU, 16+ GB RAM)
- Prometheus storage grows with fleet size (handled with retention policy)
- 5 custom dashboards cover all operational needs

---

# ADR-006: HAProxy for Load Balancing

**Date:** 2024-08-01
**Status:** Accepted

## Context

Need to distribute API requests across multiple vLLM instances serving the same model.

## Decision

HAProxy with per-model backend pools, health checking, and rate limiting.

## Rationale

- L7 load balancing: route by model name in URL path
- Health checks: remove unhealthy backends automatically
- Rate limiting: protect GPU fleet from request storms
- TLS termination: single point for certificate management
- leastconn algorithm: optimal for variable-duration LLM requests
- Active/passive HA with keepalived
- Low overhead, battle-tested for high-throughput scenarios

## Consequences

- Single point of routing (HA pair mitigates)
- TLS termination means backend traffic is unencrypted (acceptable on private VLAN)
- Connection draining needed for rolling updates (implemented in playbook)
