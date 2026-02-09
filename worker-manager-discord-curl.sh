#!/bin/bash
#
# worker-manager-discord-curl.sh - Manage Discord workers using curl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config
if [[ -f "${SCRIPT_DIR}/discord-config.env" ]]; then
    source "${SCRIPT_DIR}/discord-config.env"
fi

WORKERS="${WORKERS:-3}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[MANAGER]${NC} $(date '+%H:%M:%S') $*"; }
warn() { echo -e "${YELLOW}[MANAGER]${NC} $(date '+%H:%M:%S') $*"; }
error() { echo -e "${RED}[MANAGER]${NC} $(date '+%H:%M:%S') $*"; }

log "======================================"
log "Discord Worker Pool Manager (curl)"
log "======================================"
log "Workers: ${WORKERS}"
log ""

# Worker tokens and IDs
WORKER_CONFIGS=(
    "worker-1:${WORKER1_TOKEN:-}"
    "worker-2:${WORKER2_TOKEN:-}"
    "worker-3:${WORKER3_TOKEN:-}"
)

declare -A WORKER_PIDS

start_worker() {
    local WORKER_NUM=$1
    local CONFIG="${WORKER_CONFIGS[$((WORKER_NUM-1))]}"
    local WORKER_ID="${CONFIG%%:*}"
    local TOKEN="${CONFIG#*:}"
    local RESTART_COUNT=0
    
    while true; do
        if [[ $RESTART_COUNT -eq 0 ]]; then
            log "Starting ${WORKER_ID}..."
        else
            warn "Restarting ${WORKER_ID} (restart #${RESTART_COUNT})..."
        fi
        
        export WORKER_ID="$WORKER_ID"
        export BOT_TOKEN="$TOKEN"
        export TASK_QUEUE_CHANNEL="${TASK_QUEUE_CHANNEL:-}"
        export RESULTS_CHANNEL="${RESULTS_CHANNEL:-}"
        export WORKER_POOL_CHANNEL="${WORKER_POOL_CHANNEL:-}"
        export POLL_INTERVAL="5"
        export MAX_IDLE_TIME="300"
        
        bash "${SCRIPT_DIR}/worker-discord-curl.sh" > >(sed "s/^/[${WORKER_ID}] /") 2>&1 &
        local PID=$!
        WORKER_PIDS[$WORKER_ID]=$PID
        
        log "${WORKER_ID} started with PID: $PID"
        
        if wait $PID; then
            log "${WORKER_ID} exited cleanly"
        else
            warn "${WORKER_ID} exited with error"
        fi
        
        RESTART_COUNT=$((RESTART_COUNT + 1))
        sleep 2
    done
}

shutdown() {
    error "Shutting down worker pool..."
    for WORKER_ID in "${!WORKER_PIDS[@]}"; do
        kill ${WORKER_PIDS[$WORKER_ID]} 2>/dev/null || true
    done
    sleep 2
    pkill -f "worker-discord-curl.sh" 2>/dev/null || true
    log "Shutdown complete"
    exit 0
}

trap shutdown SIGINT SIGTERM

# Check for config
if [[ ! -f "${SCRIPT_DIR}/discord-config.env" ]]; then
    warn "Config file not found: ${SCRIPT_DIR}/discord-config.env"
    warn "Run ./setup-discord.sh first"
    exit 1
fi

# Start workers
for i in $(seq 1 $WORKERS); do
    start_worker $i &
done

sleep 3

log ""
log "✓ All Discord workers started"
log "Press 'q' to quit, Ctrl+C to stop"
log ""

while true; do
    read -t 1 -n 1 INPUT || true
    [[ "$INPUT" == "q" ]] && shutdown
done
