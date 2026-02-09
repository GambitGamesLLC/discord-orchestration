#!/bin/bash
#
# worker-manager.sh - Manage a pool of workers with auto-restart
#
# Usage: ./worker-manager.sh --workers 3 --channel channel-id

set -euo pipefail

WORKERS="${WORKERS:-3}"
DISCORD_CHANNEL="${DISCORD_CHANNEL:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[MANAGER]${NC} $(date '+%H:%M:%S') $*"; }
warn() { echo -e "${YELLOW}[MANAGER]${NC} $(date '+%H:%M:%S') $*"; }
error() { echo -e "${RED}[MANAGER]${NC} $(date '+%H:%M:%S') $*"; }
info() { echo -e "${BLUE}[MANAGER]${NC} $(date '+%H:%M:%S') $*"; }

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --workers) WORKERS="$2"; shift 2 ;;
        --channel) DISCORD_CHANNEL="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[[ -z "${DISCORD_CHANNEL}" ]] && { error "DISCORD_CHANNEL required (use --channel)"; exit 1; }

# Setup
mkdir -p /tmp/discord-tasks
> /tmp/discord-tasks/queue.txt
> /tmp/discord-tasks/claimed.txt
> /tmp/discord-tasks/results.txt
> /tmp/discord-tasks/status.txt

# Track worker PIDs
declare -A WORKER_PIDS

log "======================================"
log "Discord Worker Pool Manager"
log "======================================"
log "Workers: ${WORKERS}"
log "Channel: ${DISCORD_CHANNEL}"
log ""

# Function to start a worker
start_worker() {
    local WORKER_NUM=$1
    local WORKER_ID="worker-${WORKER_NUM}"
    local RESTART_COUNT=0
    
    while true; do
        if [[ $RESTART_COUNT -eq 0 ]]; then
            info "Starting ${WORKER_ID}..."
        else
            warn "Restarting ${WORKER_ID} (restart #${RESTART_COUNT})..."
        fi
        
        # Export variables for worker
        export WORKER_ID="$WORKER_ID"
        export DISCORD_CHANNEL="$DISCORD_CHANNEL"
        export POLL_INTERVAL="5"
        export MAX_IDLE_TIME="300"
        
        # Start worker and capture PID
        bash "${SCRIPT_DIR}/worker.sh" > >(sed "s/^/[${WORKER_ID}] /") 2>&1 &
        local PID=$!
        WORKER_PIDS[$WORKER_ID]=$PID
        
        info "${WORKER_ID} started with PID: $PID"
        
        # Wait for worker to exit
        if wait $PID; then
            local EXIT_CODE=$?
            info "${WORKER_ID} exited cleanly (code: $EXIT_CODE)"
        else
            local EXIT_CODE=$?
            warn "${WORKER_ID} exited with error (code: $EXIT_CODE)"
        fi
        
        RESTART_COUNT=$((RESTART_COUNT + 1))
        
        # Brief pause before restart
        sleep 2
    done
}

# Function to show status
show_status() {
    echo ""
    log "======================================"
    log "Worker Pool Status"
    log "======================================"
    
    # Count active workers
    local ACTIVE=0
    for WORKER_ID in "${!WORKER_PIDS[@]}"; do
        local PID=${WORKER_PIDS[$WORKER_ID]}
        if kill -0 $PID 2>/dev/null; then
            echo -e "  ${GREEN}●${NC} ${WORKER_ID} (PID: $PID) - Running"
            ACTIVE=$((ACTIVE + 1))
        else
            echo -e "  ${RED}●${NC} ${WORKER_ID} (PID: $PID) - Stopped"
        fi
    done
    
    # Queue stats
    local QUEUE_SIZE=$(grep -c "^task-" /tmp/discord-tasks/queue.txt 2>/dev/null || echo "0")
    local CLAIMED=$(grep -c "task-" /tmp/discord-tasks/claimed.txt 2>/dev/null || echo "0")
    local COMPLETED=$(grep -c "SUCCESS\|FAILED" /tmp/discord-tasks/results.txt 2>/dev/null || echo "0")
    
    log ""
    log "Queue Stats:"
    log "  Pending:   $((QUEUE_SIZE - CLAIMED))"
    log "  Claimed:   $CLAIMED"
    log "  Completed: $COMPLETED"
    log ""
    log "Active Workers: $ACTIVE / $WORKERS"
    log "======================================"
}

# Function to shutdown cleanly
shutdown() {
    error "Shutting down worker pool..."
    
    # Kill all workers
    for WORKER_ID in "${!WORKER_PIDS[@]}"; do
        local PID=${WORKER_PIDS[$WORKER_ID]}
        if kill -0 $PID 2>/dev/null; then
            info "Stopping ${WORKER_ID} (PID: $PID)..."
            kill $PID 2>/dev/null || true
        fi
    done
    
    # Wait for cleanup
    sleep 2
    
    # Force kill any remaining
    pkill -f "worker.sh" 2>/dev/null || true
    
    log "Worker pool shutdown complete"
    exit 0
}

# Trap signals for clean shutdown
trap shutdown SIGINT SIGTERM

# Start workers in background
log "Starting worker pool..."
for i in $(seq 1 $WORKERS); do
    start_worker $i &
done

# Give workers time to start
sleep 3

log ""
log "✓ All workers started"
log ""
log "Commands:"
log "  Press 's' for status"
log "  Press 'q' to quit"
log "  Press Ctrl+C to stop"
log ""

# Main loop - handle user input and monitor
while true; do
    # Check if any workers are still running
    local ANY_RUNNING=false
    for WORKER_ID in "${!WORKER_PIDS[@]}"; do
        if kill -0 ${WORKER_PIDS[$WORKER_ID]} 2>/dev/null; then
            ANY_RUNNING=true
            break
        fi
    done
    
    if [[ "$ANY_RUNNING" == "false" ]]; then
        error "All workers have stopped!"
        break
    fi
    
    # Non-blocking input check
    read -t 1 -n 1 INPUT || true
    
    case "$INPUT" in
        s|S)
            show_status
            ;;
        q|Q)
            shutdown
            ;;
        *)
            # Continue monitoring
            ;;
    esac
done
