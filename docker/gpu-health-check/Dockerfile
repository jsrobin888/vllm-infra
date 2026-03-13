# =============================================================================
# GPU Health Check — Docker Image
# Phase 09: GPU Configuration — Stages 39-47
# =============================================================================
# Lightweight container that validates GPU health.
# Used in CI/CD pipelines, pre-deployment checks, and scheduled health audits.
# =============================================================================

FROM nvidia/cuda:12.4.0-base-ubuntu22.04

LABEL maintainer="infra-team"
LABEL description="GPU health validation and diagnostics container"

# --- Install utilities ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    bc \
    pciutils \
    && rm -rf /var/lib/apt/lists/*

# --- Copy health check scripts ---
COPY gpu-health-check.sh /usr/local/bin/gpu-health-check.sh
COPY gpu-diagnostics.sh /usr/local/bin/gpu-diagnostics.sh
RUN chmod +x /usr/local/bin/gpu-health-check.sh /usr/local/bin/gpu-diagnostics.sh

ENTRYPOINT ["/usr/local/bin/gpu-health-check.sh"]
