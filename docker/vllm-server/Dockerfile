# =============================================================================
# vLLM Server — Custom Docker Image
# Phase 18: Container Image Build — Stages 93-96
# =============================================================================
# Based on official vLLM image with additional tooling for production.
# Pinned to exact version for reproducibility.
# =============================================================================

ARG VLLM_VERSION=0.8.3
FROM vllm/vllm-openai:v${VLLM_VERSION}

LABEL maintainer="infra-team"
LABEL description="Production vLLM server with monitoring and health tooling"
LABEL version="${VLLM_VERSION}"

# --- Install additional utilities ---
USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    wget \
    jq \
    netcat-openbsd \
    procps \
    htop \
    nvtop \
    iproute2 \
    dnsutils \
    && rm -rf /var/lib/apt/lists/*

# --- Health check script ---
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/healthcheck.sh

# --- Startup wrapper ---
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# --- Create non-root user for running vLLM ---
RUN groupadd -g 1000 vllm && \
    useradd -u 1000 -g vllm -m -s /bin/bash vllm

# --- Create necessary directories ---
RUN mkdir -p /app/logs /app/cache && \
    chown -R vllm:vllm /app

# --- Set environment ---
ENV VLLM_LOGGING_LEVEL=INFO
ENV VLLM_NO_USAGE_STATS=1
ENV NCCL_DEBUG=WARN
ENV CUDA_DEVICE_MAX_CONNECTIONS=1
ENV TOKENIZERS_PARALLELISM=false

# --- Prometheus metrics port ---
EXPOSE 8000

# --- Health check ---
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

USER vllm
WORKDIR /app

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
