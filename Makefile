# =============================================================================
# Makefile — vLLM Infrastructure Operations
# =============================================================================
# Convenience targets for common operations.
# =============================================================================

.PHONY: help lint validate deploy-storage deploy-runners deploy-vllm deploy-monitoring deploy-lb \
        deploy-all health-check security-audit smoke-test benchmark fleet-report

ANSIBLE_OPTS ?= --ask-vault-pass
RUNNER ?=
MODEL ?=

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

# === Linting ===
lint: ## Lint all Ansible, YAML, and shell files
	@echo "=== Ansible Lint ==="
	ansible-lint ansible/
	@echo "=== YAML Lint ==="
	yamllint -c .yamllint ansible/ configs/
	@echo "=== ShellCheck ==="
	find scripts/ tests/ -name "*.sh" -exec shellcheck {} +

validate: ## Validate Ansible syntax and Docker Compose files
	ansible-playbook ansible/playbooks/*.yml --syntax-check
	find compose/ -name "docker-compose.yml" -exec docker compose -f {} config --quiet \;

# === Deployment ===
deploy-storage: ## Deploy storage servers
	ansible-playbook ansible/playbooks/storage-server.yml $(ANSIBLE_OPTS)

deploy-runners: ## Deploy GPU runners (full provisioning)
	ansible-playbook ansible/playbooks/gpu-runner-full.yml $(ANSIBLE_OPTS)

deploy-vllm: ## Deploy vLLM containers
	ansible-playbook ansible/playbooks/deploy-vllm.yml $(ANSIBLE_OPTS)

deploy-monitoring: ## Deploy monitoring stack
	ansible-playbook ansible/playbooks/monitoring-stack.yml $(ANSIBLE_OPTS)

deploy-lb: ## Deploy load balancers
	ansible-playbook ansible/playbooks/load-balancer.yml $(ANSIBLE_OPTS)

deploy-all: deploy-storage deploy-runners deploy-vllm deploy-monitoring deploy-lb ## Deploy everything

# === Day-2 Operations ===
update-vllm: ## Rolling update vLLM (set VERSION=x.x.x)
	ansible-playbook ansible/playbooks/rolling-update-vllm.yml \
		-e "vllm_version=$(VERSION)" $(ANSIBLE_OPTS)

download-model: ## Download a model (set MODEL=org/model-name)
	ansible-playbook ansible/playbooks/model-download.yml \
		-e "model_id=$(MODEL)" $(ANSIBLE_OPTS)

add-runner: ## Add a new GPU runner (set RUNNER=hostname)
	ansible-playbook ansible/playbooks/scale-add-runner.yml \
		-e "target_host=$(RUNNER)" $(ANSIBLE_OPTS)

remove-runner: ## Remove a GPU runner (set RUNNER=hostname)
	ansible-playbook ansible/playbooks/scale-remove-runner.yml \
		-e "target_host=$(RUNNER)" $(ANSIBLE_OPTS)

# === Verification ===
health-check: ## Run fleet health check
	ansible-playbook ansible/playbooks/fleet-health-check.yml $(ANSIBLE_OPTS)

security-audit: ## Run security audit
	ansible-playbook ansible/playbooks/security-audit.yml $(ANSIBLE_OPTS)

smoke-test: ## Run smoke tests (set URL=http://host:port)
	tests/smoke/test-vllm-endpoint.sh $(URL)

integration-test: ## Run full integration tests
	tests/integration/test-full-stack.sh

benchmark: ## Run performance benchmark (set URL=http://host:port MODEL=name)
	scripts/benchmarks/vllm-benchmark.sh $(URL) $(MODEL)

# === Reporting ===
fleet-report: ## Generate fleet inventory report
	scripts/reporting/fleet-inventory.sh

# === Utilities ===
encrypt-vault: ## Encrypt vault file
	ansible-vault encrypt ansible/group_vars/all/vault.yml

edit-vault: ## Edit vault file
	ansible-vault edit ansible/group_vars/all/vault.yml

gen-cert: ## Generate self-signed TLS certificate
	scripts/security/cert-manager.sh generate-self-signed

check-cert: ## Check TLS certificate expiry
	scripts/security/cert-manager.sh check-expiry
