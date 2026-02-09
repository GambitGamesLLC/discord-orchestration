#!/bin/bash
#
# worker-reaction-fixed.sh - Fixed reaction-based task claiming

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

# Check for tasks via reactions - outputs ONLY the task or nothing
get_task_via_reactions() {
    [[ -z "$BOT_TOKEN" || -z "$TASK_QUEUE_CHANNEL" ]] && return 0
    
    # Fetch last 10 messages
    local MESSAGES
    MESSAGES=$(discord_api GET "/channels/${TASK_QUEUE_CHANNEL}/messages?limit=10")
    
    [[ -z "$MESSAGES" ]] && return 0
    
    # Get message IDs (one per line)
    local MSG_IDS
    MSG_IDS=$(echo "$MESSAGES" | python3 -c "import json,sys; data=json.load(sys.stdin); [print(m['id']) for m in data]" 2>/dev/null)
    
    [[ -z "$MSG_IDS" ]] && return 0
    
    # Check each message
    while IFS= read -r MSG_ID; do
        [[ -z "$MSG_ID" ]] && continue
        
        # Check if already has ✅ reaction
        local REACTIONS
        REACTIONS=$(discord_api GET "/channels/${TASK_QUEUE_CHANNEL}/messages/${MSG_ID}/reactions/%E2%9C%85")
        
        # If no reactions yet, try to claim
        if [[ -z "$REACTIONS" ]] || [[ "$REACTIONS" == "[]" ]]; then
            # Try to add ✅ reaction (atomic claim)
            local CLAIM_RESPONSE
            CLAIM_RESPONSE=$(curl -s -X PUT \
                -H "Authorization: Bot ${BOT_TOKEN}" \
                "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL}/messages/${MSG_ID}/reactions/%E2%9C%85/@me" 2>&1)
            
            # If successful (empty response), we claimed it
            if [[ -z "$CLAIM_RESPONSE" ]]; then
                # Get message content
                local MSG_DATA
                MSG_DATA=$(discord_api GET "/channels/${TASK_QUEUE_CHANNEL}/messages/${MSG_ID}")
                
                local CONTENT
                CONTENT=$(echo "$MSG_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['content'])" 2>/dev/null)
                
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
                    
                    # Output ONLY the task (this goes to stdout)
                    echo "discord-${MSG_ID}|${TASK_DESC}|${MODEL}|${THINKING}"
                    return 0
                fi
            fi
        fi
    done <<< "$MSG_IDS"
    
    return 0
}

# Fallback to file-based - outputs ONLY the task or nothing
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
    local REQUESTED_MODEL=$(echo "$TASK_DATA" | cut -d'|' -f3)
    local THINKING=$(echo "$TASK_DATA" | cut -d'|' -f4)
    
    # Validate model is available, fallback to default if not
    local MODEL="$REQUESTED_MODEL"
    if ! openclaw models list 2>/dev/null | grep -q "$MODEL"; then
        echo "[$(date '+%H:%M:%S')] ⚠️ Model '$MODEL' not available, using default"
        MODEL="openrouter/moonshotai/kimi-k2.5"  # Default fallback
    fi
    
    # Export MODEL so post_result can see actual model used
    export ACTUAL_MODEL="$MODEL"
    
    echo "[$(date '+%H:%M:%S')] Executing: ${TASK_DESC:0:50}..."
    echo "[$(date '+%H:%M:%S')] Using model: $MODEL"
    
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
        --model "$MODEL" \
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
    local MODEL="$3"
    local THINKING="$4"
    local TOKENS_IN="${5:-unknown}"
    local TOKENS_OUT="${6:-unknown}"
    
    local TASK_ID=$(echo "$TASK_DATA" | cut -d'|' -f1)
    local RESULT_FILE="/tmp/discord-workers/${WORKER_ID}/${TASK_ID}/RESULT.txt"
    local RESULT=""
    [[ -f "$RESULT_FILE" ]] && RESULT=$(head -c 400 "$RESULT_FILE")
    
    # Local log with full details
    echo "${TASK_ID}|${WORKER_ID}|${STATUS}|$(date +%s)|${MODEL}|${THINKING}|${TOKENS_IN}|${TOKENS_OUT}|${RESULT:0:300}" >> /tmp/discord-tasks/results.txt
    
    # Discord message with enhanced info
    local MSG="**[${STATUS}]** \`${TASK_ID}\` by **${WORKER_ID}**
**Model:** ${MODEL}
**Thinking:** ${THINKING}
**Tokens:** ${TOKENS_IN} in / ${TOKENS_OUT} out

\`\`\`
${RESULT:0:200}
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
        
        # Extract task details for reporting
        TASK_MODEL=$(echo "$TASK" | cut -d'|' -f3)
        TASK_THINKING=$(echo "$TASK" | cut -d'|' -f4)
        
        post_status "CLAIMED" "Task ${TASK%%|*} | Model: ${ACTUAL_MODEL} | Thinking: ${TASK_THINKING}"
        
        if execute_task "$TASK"; then
            # Try to get token usage from agent output
            TOKENS_IN="unknown"
            TOKENS_OUT="unknown"
            
            # Look for token usage in agent output
            if [[ -f agent-output.log ]]; then
                # Try to extract from OpenClaw output (format varies)
                TOKENS_IN=$(grep -o '"input_tokens":[0-9]*' agent-output.log | head -1 | cut -d: -f2 || echo "unknown")
                TOKENS_OUT=$(grep -o '"output_tokens":[0-9]*' agent-output.log | head -1 | cut -d: -f2 || echo "unknown")
            fi
            
            post_result "SUCCESS" "$TASK" "$ACTUAL_MODEL" "$TASK_THINKING" "$TOKENS_IN" "$TOKENS_OUT"
        else
            post_result "FAILED" "$TASK" "$ACTUAL_MODEL" "$TASK_THINKING" "N/A" "N/A"
        fi
        
        post_status "RESTARTING" "Task complete"
        exit 0
    fi
    
    sleep $POLL_INTERVAL
    IDLE_TIME=$((IDLE_TIME + POLL_INTERVAL))
done

post_status "IDLE" "Timeout after ${MAX_IDLE_TIME}s"
exit 0
