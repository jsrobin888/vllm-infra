#!/bin/bash
# =============================================================================
# NFS Replication Script — Primary → Secondary
# Phase 14: Storage Redundancy — Stages 83-86
# =============================================================================
# Runs as a cron job on the secondary storage server.
# Uses rsync to replicate model data from primary.
# =============================================================================
set -euo pipefail

PRIMARY_HOST="${NFS_PRIMARY:-storage-primary.internal}"
SOURCE_PATH="/data/models/"
DEST_PATH="/data/models/"
LOG_FILE="/var/log/nfs-replication.log"
LOCK_FILE="/tmp/nfs-replication.lock"
BANDWIDTH_LIMIT="${BW_LIMIT:-0}"  # KB/s, 0 = unlimited

# --- Locking ---
if [[ -f "$LOCK_FILE" ]]; then
    PID=$(cat "$LOCK_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo "$(date -u '+%Y-%m-%d %H:%M:%S') Replication already running (PID: $PID)" >> "$LOG_FILE"
        exit 0
    fi
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# --- Replication ---
log() { echo "$(date -u '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; }

log "Starting replication from ${PRIMARY_HOST}:${SOURCE_PATH}"

RSYNC_OPTS=(
    -avz
    --delete
    --timeout=300
    --contimeout=30
    --stats
    --human-readable
    --exclude='.snapshot/'
    --exclude='lost+found/'
)

if [[ "$BANDWIDTH_LIMIT" -gt 0 ]]; then
    RSYNC_OPTS+=(--bwlimit="$BANDWIDTH_LIMIT")
fi

START_TIME=$(date +%s)

if rsync "${RSYNC_OPTS[@]}" \
    "rsync://${PRIMARY_HOST}${SOURCE_PATH}" \
    "${DEST_PATH}" >> "$LOG_FILE" 2>&1; then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    log "Replication completed successfully in ${DURATION}s"

    # Update last-sync timestamp
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "${DEST_PATH}/.last_sync"
else
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    log "ERROR: Replication failed after ${DURATION}s (exit code: $?)"
    exit 1
fi
