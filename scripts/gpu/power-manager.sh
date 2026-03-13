#!/bin/bash
# =============================================================================
# GPU Power Management — Phase 31 (Stages 199–204)
# =============================================================================
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME <command> [options]

Commands:
  status              Show current power status of all GPUs
  set <watts>         Set power limit on all GPUs (requires root)
  set <gpu_id> <W>    Set power limit on specific GPU
  profile <name>      Apply named power profile
  schedule            Show/set time-based power schedules
  monitor             Continuous power monitoring (Ctrl+C to stop)

Profiles:
  max-performance     Maximum power, maximum clocks
  balanced            Default power limits, auto clocks
  power-saver         Reduced power for off-peak hours
  custom <watts>      Custom wattage limit

Examples:
  $SCRIPT_NAME status
  $SCRIPT_NAME set 250
  $SCRIPT_NAME set 0 300
  $SCRIPT_NAME profile balanced
  $SCRIPT_NAME monitor
EOF
}

GPU_COUNT=$(nvidia-smi --query-gpu=count --format=csv,noheader | head -1)

cmd_status() {
    echo "=== GPU Power Status ==="
    echo ""
    printf "%-6s %-20s %-12s %-12s %-10s %-10s %-10s\n" \
        "GPU" "NAME" "POWER DRAW" "POWER LIMIT" "MIN LIMIT" "MAX LIMIT" "TEMP"
    printf "%-6s %-20s %-12s %-12s %-10s %-10s %-10s\n" \
        "---" "----" "----------" "-----------" "---------" "---------" "----"

    for i in $(seq 0 $((GPU_COUNT - 1))); do
        NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader -i $i | xargs)
        DRAW=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader -i $i | xargs)
        LIMIT=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader -i $i | xargs)
        MIN=$(nvidia-smi --query-gpu=power.min_limit --format=csv,noheader -i $i | xargs)
        MAX=$(nvidia-smi --query-gpu=power.max_limit --format=csv,noheader -i $i | xargs)
        TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader -i $i | xargs)

        printf "%-6s %-20s %-12s %-12s %-10s %-10s %-10s\n" \
            "$i" "$NAME" "$DRAW" "$LIMIT" "$MIN" "$MAX" "${TEMP}°C"
    done

    echo ""
    TOTAL_DRAW=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits | paste -sd+ | bc)
    TOTAL_LIMIT=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits | paste -sd+ | bc)
    echo "Total Power: ${TOTAL_DRAW}W / ${TOTAL_LIMIT}W limit"
    echo "Efficiency:  $(echo "scale=1; $TOTAL_DRAW / $TOTAL_LIMIT * 100" | bc)%"
}

cmd_set() {
    if [ $# -eq 1 ]; then
        # Set all GPUs
        local watts=$1
        echo "Setting all $GPU_COUNT GPUs to ${watts}W..."
        for i in $(seq 0 $((GPU_COUNT - 1))); do
            nvidia-smi -i $i -pl "$watts"
            echo "  GPU $i: power limit set to ${watts}W"
        done
    elif [ $# -eq 2 ]; then
        # Set specific GPU
        local gpu_id=$1
        local watts=$2
        echo "Setting GPU $gpu_id to ${watts}W..."
        nvidia-smi -i "$gpu_id" -pl "$watts"
    else
        echo "Usage: $SCRIPT_NAME set <watts> OR $SCRIPT_NAME set <gpu_id> <watts>"
        exit 1
    fi
}

cmd_profile() {
    local profile="${1:-balanced}"

    case $profile in
        max-performance)
            echo "Applying MAX PERFORMANCE profile..."
            for i in $(seq 0 $((GPU_COUNT - 1))); do
                MAX=$(nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits -i $i | xargs)
                nvidia-smi -i $i -pl "$MAX"
                # Unlock clocks (remove any constraints)
                nvidia-smi -i $i -rgc 2>/dev/null || true
                echo "  GPU $i: ${MAX}W, clocks unrestricted"
            done
            ;;
        balanced)
            echo "Applying BALANCED profile..."
            for i in $(seq 0 $((GPU_COUNT - 1))); do
                MAX=$(nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits -i $i | xargs)
                DEFAULT=$(echo "scale=0; $MAX * 0.85" | bc | cut -d'.' -f1)
                nvidia-smi -i $i -pl "$DEFAULT"
                echo "  GPU $i: ${DEFAULT}W (85% of max)"
            done
            ;;
        power-saver)
            echo "Applying POWER SAVER profile..."
            for i in $(seq 0 $((GPU_COUNT - 1))); do
                MIN=$(nvidia-smi --query-gpu=power.min_limit --format=csv,noheader,nounits -i $i | xargs)
                MAX=$(nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits -i $i | xargs)
                # Set to 60% of max, but not below minimum
                TARGET=$(echo "scale=0; $MAX * 0.60" | bc | cut -d'.' -f1)
                if [ "$TARGET" -lt "${MIN%.*}" ]; then
                    TARGET="${MIN%.*}"
                fi
                nvidia-smi -i $i -pl "$TARGET"
                echo "  GPU $i: ${TARGET}W (60% of max)"
            done
            ;;
        custom)
            if [ -z "${2:-}" ]; then
                echo "Usage: $SCRIPT_NAME profile custom <watts>"
                exit 1
            fi
            cmd_set "$2"
            ;;
        *)
            echo "Unknown profile: $profile"
            echo "Available: max-performance, balanced, power-saver, custom <watts>"
            exit 1
            ;;
    esac

    echo ""
    cmd_status
}

cmd_monitor() {
    echo "=== GPU Power Monitor (Ctrl+C to stop) ==="
    echo ""
    while true; do
        clear
        echo "=== GPU Power Monitor — $(date -u +%H:%M:%S) ==="
        echo ""
        cmd_status
        echo ""
        echo "Refresh: 5s | Press Ctrl+C to stop"
        sleep 5
    done
}

# Main
case "${1:-}" in
    status)  cmd_status ;;
    set)     shift; cmd_set "$@" ;;
    profile) shift; cmd_profile "$@" ;;
    monitor) cmd_monitor ;;
    *)       usage ;;
esac
