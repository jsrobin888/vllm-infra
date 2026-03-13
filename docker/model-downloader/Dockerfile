# =============================================================================
# Model Downloader — Docker Image
# Phase 13: Model Lifecycle — Stages 77-82
# =============================================================================
# Utility container for downloading models from HuggingFace Hub
# to the NFS storage server. Runs as a one-shot job.
# =============================================================================

FROM python:3.11-slim-bookworm

LABEL maintainer="infra-team"
LABEL description="HuggingFace model downloader for NFS storage"

# --- Install dependencies ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    git \
    git-lfs \
    && rm -rf /var/lib/apt/lists/*

# --- Install Python packages ---
RUN pip install --no-cache-dir \
    huggingface-hub==0.24.5 \
    hf-transfer==0.1.8 \
    tqdm \
    requests

# --- Enable hf-transfer for fast downloads ---
ENV HF_HUB_ENABLE_HF_TRANSFER=1

# --- Create working directories ---
RUN mkdir -p /models /metadata /checksums

# --- Copy download script ---
COPY download-model.sh /usr/local/bin/download-model.sh
RUN chmod +x /usr/local/bin/download-model.sh

# --- Copy metadata generator ---
COPY generate-metadata.sh /usr/local/bin/generate-metadata.sh
RUN chmod +x /usr/local/bin/generate-metadata.sh

# --- Non-root user ---
RUN groupadd -g 1000 downloader && \
    useradd -u 1000 -g downloader -m downloader
RUN chown -R downloader:downloader /models /metadata /checksums

USER downloader
WORKDIR /models

ENTRYPOINT ["/usr/local/bin/download-model.sh"]
