#!/bin/bash
#
# worker-reaction.sh - Reaction-based task claiming
#
# Workers claim tasks by adding ✅ reaction (atomic operation)

set -euo pipefail

WORKER_ID="${WORKER_ID:-worker-unknown}"
BOT_TOKEN="${BOT_TOKEN:-}"
TASK_QUEUE_CHANNEL="${TASK_QUEUE_CHANNEL:-}"
RESULTS_CHANNEL="${RESULTS_CHANNEL:-}"
WORKER_POOL_CHANNEL="${WORKER_POOL_CHANNEL:-}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
MAX_IDLE_TIME="${MAX_IDLE_TIME:-300}"

# Discord API helper
discord_api() {
    local METHOD="$1"
    local ENDPOINT="$2"
    local DATA="${3:-}"
    
    if [[ -n "$DATA" ]]; then
        curl -s -X "$METHOD" \
            -H "Authorization: Bot ${BOT_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$DATA" \
            "https://discord.com/api/v10${ENDPOINT}" 2>/dev/null
    else
        curl -s -X "$METHOD" \
            -H "Authorization: Bot ${BOT_TOKEN}" \
            "https://discord.com/api/v10${ENDPOINT}" 2>/dev/null
    fi
}

post_to_discord() {
    local CHANNEL="$1"
    local MESSAGE="$2"
    [[ -z "$BOT_TOKEN" ]] && return 0
    
    local JSON_MSG
    JSON_MSG=$(echo "$MESSAGE" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    discord_api POST "/channels/${CHANNEL}/messages" "{\"content\":\"${JSON_MSG}\"}" > /dev/null
}

# Check for tasks via reactions
get_task_via_reactions() {
    [[ -z "$BOT_TOKEN" || -z "$TASK_QUEUE_CHANNEL" ]] && return 0
    
    # Fetch last 10 messages
    local MESSAGES
    MESSAGES=$(discord_api GET "/channels/${TASK_QUEUE_CHANNEL}/messages?limit=10")
    
    [[ -z "$MESSAGES" ]] && return 0
    
    # Parse each message ID (only top-level message IDs, not nested user IDs)
    # Messages are in format: {"id":"12345","content":"...",...}
    echo "$MESSAGES" | grep -o '"id":"[0-9]*"' | head -10 | sed 's/"id":"//;s/"$//' | while read -r MSG_ID; do
        # Check if already has ✅ reaction
        local REACTIONS
        REACTIONS=$(discord_api GET "/channels/${TASK_QUEUE_CHANNEL}/messages/${MSG_ID}/reactions/%E2%9C%85")
        
        # If no reactions yet, try to claim
        if [[ -z "$REACTIONS" ]] || ! echo "$REACTIONS" | grep -q '"id"'; then
            # Try to add ✅ reaction (atomic claim)
            echo "[$(date '+%H:%M:%S')] Attempting to claim task ${MSG_ID:0:12}..." >&2
            
            local CLAIM_RESPONSE
            CLAIM_RESPONSE=$(curl -s -X PUT \
                -H "Authorization: Bot ${BOT_TOKEN}" \
                "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL}/messages/${MSG_ID}/reactions/%E2%9C%85/@me" 2>&1)
            
            # If successful (empty response), we claimed it
            if [[ -z "$CLAIM_RESPONSE" ]]; then
                echo "[$(date '+%H:%M:%S')] ✅ Claimed task via reaction (MSG: ${MSG_ID:0:12}...)" >&2
                
                # Get message content
                local MSG_DATA
                MSG_DATA=$(discord_api GET "/channels/${TASK_QUEUE_CHANNEL}/messages/${MSG_ID}")
            else
                echo "[$(date '+%H:%M:%S')] ⚠️ Failed to claim ${MSG_ID:0:12}: ${CLAIM_RESPONSE:0:50}" >&2
                
                local CONTENT
                CONTENT=$(echo "$MSG_DATA" | grep -o '"content":"[^"]*"' | head -1 | sed 's/"content":"//;s/"$//')
                
                if [[ -n "$CONTENT" ]]; then
                    # Parse task
                    local TASK_DESC="$CONTENT"
                    local MODEL="openrouter/moonshotai/kimi-k2.5"
                    local THINKING="medium"
                    
                    # Extract model [model:xxx]
                    if [[ "$CONTENT" =~ \[model:([^\]]+)\] ]]; then
                        MODEL="${BASH_REMATCH[1]}"
                        TASK_DESC="${TASK_DESC/\[model:$MODEL\]/}"
                    fi
                    
                    # Extract thinking [thinking:xxx]
                    if [[ "$CONTENT" =~ \[thinking:([^\]]+)\] ]]; then
                        THINKING="${BASH_REMATCH[1]}"
                        TASK_DESC="${TASK_DESC/\[thinking:$THINKING\]/}"
                    fi
                    
                    TASK_DESC=$(echo "$TASK_DESC" | sed 's/^ *//;s/ *$//')
                    
                    # Return task
                    echo "discord-${MSG_ID}|${TASK_DESC}|${MODEL}|${THINKING}"
                    return 0
                fi
            fi
        fi
    done
}

# Fallback to file-based
get_task_from_file() {
    local QUEUE_FILE="/tmp/discord-tasks/queue.txt"
    local CLAIMED_FILE="/tmp/discord-tasks/claimed.txt"
    local LOCK_FILE="/tmp/discord-tasks/queue.lock"
    
    mkdir -p "$(dirname "$QUEUE_FILE")" 2>/dev/null || return 0
    [[ ! -f "$QUEUE_FILE" ]] && return 0
    [[ ! -s "$QUEUE_FILE" ]] && return 0
    
    # Try lock
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
    
    echo "${TASK_ID}|${WORKER_ID}|${STATUS}|$(date +%s)|${RESULT:0:300}" >> /tmp/discord-tasks/results.txt
    
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

IDLE_TIME=0
while [[ $IDLE_TIME -lt $MAX_IDLE_TIME ]]; do
    # Try Discord first, then file fallback
    TASK=$(get_task_via_reactions)
    
    if [[ -z "$TASK" ]]; then
        TASK=$(get_task_from_file)
    fi
    
    if [[ -n "$TASK" ]]; then
        echo "[$(date '+%H:%M:%S')] Task: ${TASK:0:40}..."
        post_status "CLAIMED" "Task ${TASK%%|*}"
        
        # Add 🔄 reaction to show in-progress
        if [[ "$TASK" == discord-* ]]; then
            MSG_ID="${TASK:8}"  # Remove "discord-" prefix
            MSG_ID="${MSG_ID%%|*}"    # Get just the ID
            discord_api PUT "/channels/${TASK_QUEUE_CHANNEL}/messages/${MSG_ID}/reactions/%F0%9F%94%84/@me" > /dev/null 2>&1 || true
        fi
        
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
