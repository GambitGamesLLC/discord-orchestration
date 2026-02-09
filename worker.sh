#!/bin/bash
#
# worker.sh - Discord-Coordinated Worker (Phase 0)
#
# Usage: WORKER_ID="worker-1" DISCORD_CHANNEL="channel-id" ./worker.sh
#
# This worker:
# 1. Starts up and posts READY status to Discord
# 2. Polls for tasks
# 3. Executes one task
# 4. Posts result
# 5. Exits (context reset via process restart)

set -euo pipefail

# =============================================================================
# Functions (defined before use)
# =============================================================================

check_for_task() {
    # PHASE 0: Simulate with file-based queue with atomic locking
    # In production, this queries Discord
    
    QUEUE_FILE="/tmp/discord-tasks/queue.txt"
    CLAIMED_FILE="/tmp/discord-tasks/claimed.txt"
    LOCK_FILE="/tmp/discord-tasks/queue.lock"
    
    mkdir -p "$(dirname "$QUEUE_FILE")"
    touch "$QUEUE_FILE" "$CLAIMED_FILE"
    
    # Acquire exclusive lock (wait up to 5 seconds)
    local lock_acquired=false
    local lock_wait=0
    while [[ $lock_wait -lt 50 ]]; do
        if mkdir "$LOCK_FILE" 2>/dev/null; then
            lock_acquired=true
            break
        fi
        sleep 0.1
        lock_wait=$((lock_wait + 1))
    done
    
    if [[ "$lock_acquired" == "false" ]]; then
        echo "[$(date '+%H:%M:%S')] Could not acquire lock, retrying..." >&2
        return 1
    fi
    
    # Critical section - we have the lock
    local found_task=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        
        local task_id
        task_id=$(echo "$line" | cut -d'|' -f1)
        [[ -z "$task_id" ]] && continue
        
        # Check if already claimed
        if ! grep -q "^${task_id}" "$CLAIMED_FILE" 2>/dev/null; then
            # Claim it atomically
            echo "${task_id}|${WORKER_ID}|$(date +%s)" >> "$CLAIMED_FILE"
            found_task="$line"
            break
        fi
    done < "$QUEUE_FILE"
    
    # Release lock
    rm -rf "$LOCK_FILE"
    
    if [[ -n "$found_task" ]]; then
        echo "$found_task"
        return 0
    fi
    
    return 1
}

execute_task() {
    local TASK_DATA="$1"
    
    # Parse task
    TASK_ID=$(echo "$TASK_DATA" | cut -d'|' -f1)
    TASK_DESC=$(echo "$TASK_DATA" | cut -d'|' -f2)
    MODEL=$(echo "$TASK_DATA" | cut -d'|' -f3)
    THINKING=$(echo "$TASK_DATA" | cut -d'|' -f4)
    
    echo "[$(date '+%H:%M:%S')] Executing: $TASK_DESC"
    
    # Create workspace
    WORKSPACE="/tmp/discord-workers/${WORKER_ID}/${TASK_ID}"
    mkdir -p "$WORKSPACE"
    
    # Write task files
    cat > "$WORKSPACE/TASK.txt" << EOF
TASK: ${TASK_DESC}

Complete this task and write your result to RESULT.txt.
EOF

    cat > "$WORKSPACE/AGENTS.md" << EOF
# Worker ${WORKER_ID}

Task: ${TASK_DESC}

Complete the task described in TASK.txt.
Write your result to RESULT.txt.
End with "TASK COMPLETE".
EOF

    # Run OpenClaw agent
    cd "$WORKSPACE"
    
    # Copy to OpenClaw workspace
    cp AGENTS.md TASK.txt "$HOME/.openclaw/workspace/" 2>/dev/null || true
    
    echo "[$(date '+%H:%M:%S')] Running OpenClaw agent..."
    
    # Execute with timeout
    if timeout 120 $OPENCLAW_BIN agent --local \
        --session-id "${WORKER_ID}-${TASK_ID}" \
        --message "Complete the task in TASK.txt. Write detailed result to RESULT.txt." \
        --thinking "$THINKING" \
        > agent-output.log 2>&1; then
        
        echo "[$(date '+%H:%M:%S')] Agent command completed"
        
        # Check if result was written (in OpenClaw workspace)
        OPENCLAW_RESULT="$HOME/.openclaw/workspace/RESULT.txt"
        if [[ -f "$OPENCLAW_RESULT" ]]; then
            echo "[$(date '+%H:%M:%S')] Result captured"
            # Copy result to our workspace
            cp "$OPENCLAW_RESULT" RESULT.txt
            return 0
        else
            echo "[$(date '+%H:%M:%S')] WARNING: Agent ran but RESULT.txt not found"
            echo "[$(date '+%H:%M:%S')] Agent output:"
            cat agent-output.log | head -20
            return 1
        fi
    else
        local exit_code=$?
        echo "[$(date '+%H:%M:%S')] Agent failed with exit code: $exit_code"
        echo "[$(date '+%H:%M:%S')] Agent output:"
        cat agent-output.log | head -20
        return 1
    fi
}

post_result() {
    local STATUS="$1"
    local TASK_DATA="$2"
    
    TASK_ID=$(echo "$TASK_DATA" | cut -d'|' -f1)
    
    # Read result if available (check both locations)
    RESULT_FILE="/tmp/discord-workers/${WORKER_ID}/${TASK_ID}/RESULT.txt"
    OPENCLAW_RESULT="$HOME/.openclaw/workspace/RESULT.txt"
    RESULT=""
    
    if [[ -f "$RESULT_FILE" ]]; then
        RESULT=$(cat "$RESULT_FILE")
    elif [[ -f "$OPENCLAW_RESULT" ]]; then
        RESULT=$(cat "$OPENCLAW_RESULT")
    fi
    
    # Post to results
    echo "[RESULT] Worker: ${WORKER_ID} | Task: ${TASK_ID} | Status: ${STATUS}"
    echo "Result: ${RESULT:0:200}..."
    
    # PHASE 0: Write to file
    # In production, post to Discord
    echo "${TASK_ID}|${WORKER_ID}|${STATUS}|$(date +%s)|${RESULT:0:500}" \
        >> /tmp/discord-tasks/results.txt
}

post_status() {
    local STATUS="$1"
    local MESSAGE="$2"
    
    echo "[STATUS] ${WORKER_ID}: ${STATUS} - ${MESSAGE}"
    
    # PHASE 0: Write to file
    mkdir -p /tmp/discord-tasks
    echo "$(date +%s)|${WORKER_ID}|${STATUS}|${MESSAGE}" \
        >> /tmp/discord-tasks/status.txt
}

# =============================================================================
# Main Script
# =============================================================================

# Configuration
WORKER_ID="${WORKER_ID:-worker-$(hostname)-$$}"
DISCORD_CHANNEL="${DISCORD_CHANNEL:-}"
TASK_QUEUE_CHANNEL="${TASK_QUEUE_CHANNEL:-${DISCORD_CHANNEL}}"
RESULTS_CHANNEL="${RESULTS_CHANNEL:-${DISCORD_CHANNEL}}"
STATUS_CHANNEL="${STATUS_CHANNEL:-${DISCORD_CHANNEL}}"

POLL_INTERVAL="${POLL_INTERVAL:-5}"  # Seconds between polls
MAX_IDLE_TIME="${MAX_IDLE_TIME:-300}"  # Exit after 5 min idle (prevent runaway)

OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"

echo "[$(date '+%H:%M:%S')] Worker ${WORKER_ID} starting..."

# Validate config
[[ -z "${DISCORD_CHANNEL}" ]] && { echo "ERROR: DISCORD_CHANNEL not set"; exit 1; }

# Post READY status
post_status "READY" "Worker ${WORKER_ID} online and waiting for tasks"

# Main loop - look for one task then exit
IDLE_TIME=0
while [[ $IDLE_TIME -lt $MAX_IDLE_TIME ]]; do
    echo "[$(date '+%H:%M:%S')] Polling for tasks..."
    
    # Check for task in Discord
    # For Phase 0, we simulate by checking a local file
    # In real implementation, this queries Discord API or uses openclaw message tool
    
    TASK=$(check_for_task)
    
    if [[ -n "$TASK" ]]; then
        echo "[$(date '+%H:%M:%S')] Task received: ${TASK:0:50}..."
        
        # Claim task (mark as in-progress)
        post_status "CLAIMED" "Worker ${WORKER_ID} claimed task"
        
        # Execute task
        if execute_task "$TASK"; then
            echo "[$(date '+%H:%M:%S')] Task completed successfully"
            post_result "SUCCESS" "$TASK"
        else
            echo "[$(date '+%H:%M:%S')] Task failed"
            post_result "FAILED" "$TASK"
        fi
        
        # Exit after one task (clean context via restart)
        echo "[$(date '+%H:%M:%S')] Exiting to reset context..."
        post_status "RESTARTING" "Worker ${WORKER_ID} resetting context"
        exit 0
    fi
    
    # No task, wait and try again
    sleep $POLL_INTERVAL
    IDLE_TIME=$((IDLE_TIME + POLL_INTERVAL))
done

# Idle timeout reached
echo "[$(date '+%H:%M:%S')] Idle timeout reached, exiting..."
post_status "IDLE_TIMEOUT" "Worker ${WORKER_ID} exiting after ${MAX_IDLE_TIME}s idle"
exit 0
