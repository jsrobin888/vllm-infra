# vLLM Infrastructure

## Stateless GPU Runners + Centralized Model Storage

Production-grade infrastructure for serving LLMs with vLLM, designed for
separated compute (GPU runners) and storage (NFS model server) architecture.

**66 Phases | 217 Stages | Full lifecycle coverage**

## Quick Start

```bash
# 1. Configure your inventory
cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
vim ansible/inventory/hosts.yml

# 2. Set secrets
cp ansible/group_vars/all/vault.yml.example ansible/group_vars/all/vault.yml
ansible-vault encrypt ansible/group_vars/all/vault.yml

# 3. Provision storage server
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/storage-server.yml

# 4. Download models
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/model-download.yml \
  -e model_id=meta-llama/Llama-3.1-70B-Instruct

# 5. Provision GPU runners
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/gpu-runner-full.yml

# 6. Deploy vLLM
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/deploy-vllm.yml

# 7. Deploy monitoring stack
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/monitoring-stack.yml
```

## Repository Structure

```
vllm-infra/
├── MASTER_PLAN.md                    # 66-phase, 217-stage plan
├── README.md                         # This file
├── VERSION                           # Infrastructure version
├── versions.lock                     # All pinned versions
│
├── ansible/                          # Configuration management
│   ├── ansible.cfg                   # Ansible configuration
│   ├── inventory/                    # Host inventories
│   ├── group_vars/                   # Group variables
│   ├── host_vars/                    # Per-host variables
│   ├── roles/                        # Reusable roles
│   ├── playbooks/                    # Orchestration playbooks
│   └── templates/                    # Jinja2 templates
│
├── docker/                           # Container definitions
│   ├── vllm-server/                  # vLLM server image
│   ├── model-downloader/             # Model download utility
│   └── gpu-health-check/             # GPU validation container
│
├── compose/                          # Docker Compose deployments
│   ├── vllm-single-gpu/             # Single GPU deployment
│   ├── vllm-multi-gpu/              # Multi-GPU tensor parallel
│   ├── vllm-multi-model/            # Multiple models on one runner
│   └── monitoring/                   # Prometheus + Grafana + Loki
│
├── configs/                          # Application configurations
│   ├── vllm/                         # vLLM server configs
│   ├── haproxy/                      # Load balancer configs
│   ├── nginx/                        # Reverse proxy configs
│   ├── prometheus/                   # Prometheus configs
│   ├── grafana/                      # Grafana provisioning
│   ├── alertmanager/                 # Alert routing
│   └── loki/                         # Log aggregation
│
├── scripts/                          # Operational scripts
│   ├── bootstrap/                    # Initial server setup
│   ├── gpu/                          # GPU management
│   ├── models/                       # Model lifecycle
│   ├── deploy/                       # Deployment helpers
│   ├── monitoring/                   # Monitoring utilities
│   ├── benchmarks/                   # Performance testing
│   └── disaster-recovery/            # DR procedures
│
├── systemd/                          # Systemd service units
│
├── tests/                            # Infrastructure tests
│   ├── smoke/                        # Basic smoke tests
│   ├── integration/                  # Integration tests
│   ├── performance/                  # Benchmark tests
│   └── chaos/                        # Chaos engineering
│
├── docs/                             # Documentation
│   ├── architecture/                 # Architecture docs
│   ├── runbooks/                     # Operational runbooks
│   ├── adr/                          # Architecture Decision Records
│   └── diagrams/                     # Network/architecture diagrams
│
└── ci/                               # CI/CD pipeline definitions
    ├── .gitlab-ci.yml                # GitLab CI pipeline
    └── scripts/                      # CI helper scripts
```

## Architecture Overview

See [MASTER_PLAN.md](MASTER_PLAN.md) for the full 66-phase plan.

## Requirements

- Ubuntu 22.04 LTS on all nodes
- NVIDIA GPUs (Ampere+ recommended)
- 10+ Gbps network between runners and storage
- Ansible 2.15+ on control node
- Docker 24+ on all nodes

## License

This project is licensed under the [MIT License](LICENSE).
