#!/bin/bash
#
# worker-discord-stable.sh - Stable version with Discord posting, file-based queue

set -euo pipefail

# Config
WORKER_ID="${WORKER_ID:-worker-unknown}"
BOT_TOKEN="${BOT_TOKEN:-}"
RESULTS_CHANNEL="${RESULTS_CHANNEL:-}"
WORKER_POOL_CHANNEL="${WORKER_POOL_CHANNEL:-}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
MAX_IDLE_TIME="${MAX_IDLE_TIME:-300}"

post_to_discord() {
    local CHANNEL="$1"
    local MESSAGE="$2"
    
    [[ -z "$BOT_TOKEN" ]] && return 0
    
    local JSON_MSG
    JSON_MSG=$(echo "$MESSAGE" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    
    curl -s -X POST \
        -H "Authorization: Bot ${BOT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"content\":\"${JSON_MSG}\"}" \
        "https://discord.com/api/v10/channels/${CHANNEL}/messages" \
        > /dev/null 2>&1 || true
}

get_task_from_file() {
    local QUEUE_FILE="/tmp/discord-tasks/queue.txt"
    local CLAIMED_FILE="/tmp/discord-tasks/claimed.txt"
    local LOCK_FILE="/tmp/discord-tasks/queue.lock"
    
    mkdir -p "$(dirname "$QUEUE_FILE")" 2>/dev/null || return 0
    [[ ! -f "$QUEUE_FILE" ]] && return 0
    [[ ! -s "$QUEUE_FILE" ]] && return 0
    
    # Try lock (max 5 seconds)
    local waited=0
    while ! mkdir "$LOCK_FILE" 2>/dev/null; do
        sleep 0.1
        waited=$((waited + 1))
        [[ $waited -gt 50 ]] && return 0
    done
    
    local found_task=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        local task_id=$(echo "$line" | cut -d'|' -f1)
        [[ -z "$task_id" ]] && continue
        
        if ! grep -q "^${task_id}" "$CLAIMED_FILE" 2>/dev/null; then
            echo "${task_id}|${WORKER_ID}|$(date +%s)" >> "$CLAIMED_FILE"
            found_task="$line"
            break
        fi
    done < "$QUEUE_FILE"
    
    rm -rf "$LOCK_FILE" 2>/dev/null || true
    echo "$found_task"
}

execute_task() {
    local TASK_DATA="$1"
    local TASK_ID=$(echo "$TASK_DATA" | cut -d'|' -f1)
    local TASK_DESC=$(echo "$TASK_DATA" | cut -d'|' -f2)
    local MODEL=$(echo "$TASK_DATA" | cut -d'|' -f3)
    local THINKING=$(echo "$TASK_DATA" | cut -d'|' -f4)
    
    echo "[$(date '+%H:%M:%S')] Executing: ${TASK_DESC:0:50}..."
    
    local WORKSPACE="/tmp/discord-workers/${WORKER_ID}/${TASK_ID}"
    mkdir -p "$WORKSPACE"
    
    # Write task files
    cat > "$WORKSPACE/TASK.txt" << EOF
TASK: ${TASK_DESC}
EOF

    cat > "$WORKSPACE/AGENTS.md" << EOF
# Worker ${WORKER_ID}
Task: ${TASK_DESC}
Write result to RESULT.txt
EOF

    cd "$WORKSPACE"
    cp AGENTS.md TASK.txt "$HOME/.openclaw/workspace/" 2>/dev/null || true
    
    if timeout 120 openclaw agent --local \
        --session-id "${WORKER_ID}-${TASK_ID}" \
        --message "Complete the task in TASK.txt. Write result to RESULT.txt." \
        --thinking "$THINKING" \
        > agent-output.log 2>&1; then
        
        local OPENCLAW_RESULT="$HOME/.openclaw/workspace/RESULT.txt"
        if [[ -f "$OPENCLAW_RESULT" ]]; then
            cp "$OPENCLAW_RESULT" RESULT.txt
            return 0
        fi
    fi
    return 1
}

post_result() {
    local STATUS="$1"
    local TASK_DATA="$2"
    local TASK_ID=$(echo "$TASK_DATA" | cut -d'|' -f1)
    local RESULT_FILE="/tmp/discord-workers/${WORKER_ID}/${TASK_ID}/RESULT.txt"
    local RESULT=""
    [[ -f "$RESULT_FILE" ]] && RESULT=$(head -c 400 "$RESULT_FILE")
    
    # Local log
    echo "${TASK_ID}|${WORKER_ID}|${STATUS}|$(date +%s)|${RESULT:0:300}" >> /tmp/discord-tasks/results.txt
    
    # Discord
    local MSG="**[${STATUS}]** \`${TASK_ID}\` by **${WORKER_ID}**
\`\`\`
${RESULT:0:250}
\`\`\`"
    post_to_discord "$RESULTS_CHANNEL" "$MSG"
}

post_status() {
    local STATUS="$1"
    local MSG="$2"
    echo "[STATUS] ${WORKER_ID}: ${STATUS}"
    echo "$(date +%s)|${WORKER_ID}|${STATUS}|${MSG}" >> /tmp/discord-tasks/status.txt
    post_to_discord "$WORKER_POOL_CHANNEL" "**[${STATUS}]** ${WORKER_ID}: ${MSG}"
}

# Main
echo "[$(date '+%H:%M:%S')] Worker ${WORKER_ID} starting..."
post_status "READY" "Online and waiting"

local IDLE_TIME=0
while [[ $IDLE_TIME -lt $MAX_IDLE_TIME ]]; do
    local TASK=$(get_task_from_file)
    
    if [[ -n "$TASK" ]]; then
        echo "[$(date '+%H:%M:%S')] Task: ${TASK:0:40}..."
        post_status "CLAIMED" "Task ${TASK%%|*}"
        
        if execute_task "$TASK"; then
            post_result "SUCCESS" "$TASK"
        else
            post_result "FAILED" "$TASK"
        fi
        
        post_status "RESTARTING" "Task complete"
        exit 0
    fi
    
    sleep $POLL_INTERVAL
    IDLE_TIME=$((IDLE_TIME + POLL_INTERVAL))
done

post_status "IDLE" "Timeout after ${MAX_IDLE_TIME}s"
exit 0
