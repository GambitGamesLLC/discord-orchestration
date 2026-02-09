#!/bin/bash
#
# worker-discord-curl.sh - Discord-enabled worker using curl (bypasses OpenClaw message tool)
#
# Usage: WORKER_ID="worker-1" BOT_TOKEN="token" ./worker-discord-curl.sh

set -euo pipefail

# =============================================================================
# Functions
# =============================================================================

post_to_discord() {
    local CHANNEL="$1"
    local MESSAGE="$2"
    local BOT_TOKEN="${BOT_TOKEN:-}"
    
    if [[ -z "$BOT_TOKEN" ]]; then
        echo "[$(date '+%H:%M:%S')] WARNING: No BOT_TOKEN, logging locally only"
        echo "[DISCORD→$CHANNEL] $MESSAGE"
        return 0
    fi
    
    # Escape message for JSON
    local JSON_MSG
    JSON_MSG=$(echo "$MESSAGE" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    
    # Send via Discord API
    local RESPONSE
    RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bot ${BOT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"content\":\"${JSON_MSG}\"}" \
        "https://discord.com/api/v10/channels/${CHANNEL}/messages" 2>/dev/null || echo "")
    
    if echo "$RESPONSE" | grep -q '"id"'; then
        return 0
    else
        echo "[$(date '+%H:%M:%S')] Failed to post to Discord: ${RESPONSE:0:100}"
        return 1
    fi
}

check_discord_for_task() {
    # For now, use file-based queue
    QUEUE_FILE="/tmp/discord-tasks/queue.txt"
    CLAIMED_FILE="/tmp/discord-tasks/claimed.txt"
    LOCK_FILE="/tmp/discord-tasks/queue.lock"
    
    # Ensure directories exist
    if ! mkdir -p "$(dirname "$QUEUE_FILE")" 2>/dev/null; then
        echo "ERROR: Cannot create directory" >&2
        return 0  # Return empty, don't crash
    fi
    
    touch "$QUEUE_FILE" "$CLAIMED_FILE" 2>/dev/null || true
    
    # Check if queue is empty
    if [[ ! -s "$QUEUE_FILE" ]]; then
        return 0  # Empty result
    fi
    
    # Try to acquire lock (non-blocking)
    if ! mkdir "$LOCK_FILE" 2>/dev/null; then
        # Another worker has the lock
        return 0  # Try again next poll
    fi
    
    # We have the lock - find unclaimed task
    local found_task=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        
        local task_id
        task_id=$(echo "$line" | cut -d'|' -f1)
        [[ -z "$task_id" ]] && continue
        
        if ! grep -q "^${task_id}" "$CLAIMED_FILE" 2>/dev/null; then
            echo "${task_id}|${WORKER_ID}|$(date +%s)" >> "$CLAIMED_FILE"
            found_task="$line"
            break
        fi
    done < "$QUEUE_FILE"
    
    # Release lock
    rm -rf "$LOCK_FILE" 2>/dev/null || true
    
    # Return found task (or empty if none)
    echo "$found_task"
    return 0
}

execute_task() {
    local TASK_DATA="$1"
    
    TASK_ID=$(echo "$TASK_DATA" | cut -d'|' -f1)
    TASK_DESC=$(echo "$TASK_DATA" | cut -d'|' -f2)
    MODEL=$(echo "$TASK_DATA" | cut -d'|' -f3)
    THINKING=$(echo "$TASK_DATA" | cut -d'|' -f4)
    
    echo "[$(date '+%H:%M:%S')] Executing: $TASK_DESC"
    
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

    cd "$WORKSPACE"
    cp AGENTS.md TASK.txt "$HOME/.openclaw/workspace/" 2>/dev/null || true
    
    echo "[$(date '+%H:%M:%S')] Running OpenClaw agent..."
    
    if timeout 120 openclaw agent --local \
        --session-id "${WORKER_ID}-${TASK_ID}" \
        --message "Complete the task in TASK.txt. Write detailed result to RESULT.txt." \
        --thinking "$THINKING" \
        > agent-output.log 2>&1; then
        
        echo "[$(date '+%H:%M:%S')] Agent command completed"
        
        OPENCLAW_RESULT="$HOME/.openclaw/workspace/RESULT.txt"
        if [[ -f "$OPENCLAW_RESULT" ]]; then
            cp "$OPENCLAW_RESULT" RESULT.txt
            echo "[$(date '+%H:%M:%S')] Result captured"
            return 0
        fi
    fi
    
    return 1
}

post_result_discord() {
    local STATUS="$1"
    local TASK_DATA="$2"
    
    TASK_ID=$(echo "$TASK_DATA" | cut -d'|' -f1)
    
    # Read result
    RESULT_FILE="/tmp/discord-workers/${WORKER_ID}/${TASK_ID}/RESULT.txt"
    RESULT=""
    [[ -f "$RESULT_FILE" ]] && RESULT=$(cat "$RESULT_FILE")
    
    # Truncate for Discord
    local RESULT_PREVIEW
    RESULT_PREVIEW="${RESULT:0:300}"
    if [[ ${#RESULT} -gt 300 ]]; then
        RESULT_PREVIEW="${RESULT_PREVIEW}...\n*(truncated)*"
    fi
    
    # Format message
    local DISCORD_MSG
    DISCORD_MSG="**[TASK ${STATUS}]** \`${TASK_ID}\`
**Worker:** ${WORKER_ID}
**Result Preview:**
\`\`\`
${RESULT_PREVIEW}
\`\`\`"

    # Post to Discord
    post_to_discord "$RESULTS_CHANNEL" "$DISCORD_MSG"
    
    # Also save locally
    echo "${TASK_ID}|${WORKER_ID}|${STATUS}|$(date +%s)|${RESULT:0:500}" \
        >> /tmp/discord-tasks/results.txt
}

post_status_discord() {
    local STATUS="$1"
    local MESSAGE="$2"
    
    echo "[STATUS] ${WORKER_ID}: ${STATUS} - ${MESSAGE}"
    
    # Post to Discord
    local DISCORD_MSG="**[${STATUS}]** ${WORKER_ID}: ${MESSAGE}"
    post_to_discord "$WORKER_POOL_CHANNEL" "$DISCORD_MSG"
    
    # Save locally
    mkdir -p /tmp/discord-tasks
    echo "$(date +%s)|${WORKER_ID}|${STATUS}|${MESSAGE}" \
        >> /tmp/discord-tasks/status.txt
}

# =============================================================================
# Main Script
# =============================================================================

WORKER_ID="${WORKER_ID:-worker-unknown}"
BOT_TOKEN="${BOT_TOKEN:-}"
TASK_QUEUE_CHANNEL="${TASK_QUEUE_CHANNEL:-}"
RESULTS_CHANNEL="${RESULTS_CHANNEL:-}"
WORKER_POOL_CHANNEL="${WORKER_POOL_CHANNEL:-}"

POLL_INTERVAL="${POLL_INTERVAL:-5}"
MAX_IDLE_TIME="${MAX_IDLE_TIME:-300}"

echo "[$(date '+%H:%M:%S')] Worker ${WORKER_ID} starting..."
echo "[$(date '+%H:%M:%S')] Bot Token: ${BOT_TOKEN:0:10}..."
echo "[$(date '+%H:%M:%S')] Results Channel: ${RESULTS_CHANNEL}"

# Post READY status
post_status_discord "READY" "Online and waiting for tasks"

# Main loop
IDLE_TIME=0
while [[ $IDLE_TIME -lt $MAX_IDLE_TIME ]]; do
    echo "[$(date '+%H:%M:%S')] Polling for tasks..."
    
    # Check for task with error handling
    TASK=""
    if ! TASK=$(check_discord_for_task 2>&1); then
        echo "[$(date '+%H:%M:%S')] Error checking for tasks: $TASK"
        sleep $POLL_INTERVAL
        IDLE_TIME=$((IDLE_TIME + POLL_INTERVAL))
        continue
    fi
    
    if [[ -n "$TASK" ]]; then
        echo "[$(date '+%H:%M:%S')] Task received: ${TASK:0:50}..."
        
        post_status_discord "CLAIMED" "Claimed task"
        
        if execute_task "$TASK"; then
            echo "[$(date '+%H:%M:%S')] Task completed successfully"
            post_result_discord "SUCCESS" "$TASK"
        else
            echo "[$(date '+%H:%M:%S')] Task failed"
            post_result_discord "FAILED" "$TASK"
        fi
        
        echo "[$(date '+%H:%M:%S')] Exiting to reset context..."
        post_status_discord "RESTARTING" "Resetting context"
        exit 0
    fi
    
    sleep $POLL_INTERVAL
    IDLE_TIME=$((IDLE_TIME + POLL_INTERVAL))
done

echo "[$(date '+%H:%M:%S')] Idle timeout reached, exiting..."
post_status_discord "IDLE_TIMEOUT" "Exiting after ${MAX_IDLE_TIME}s idle"
exit 0
