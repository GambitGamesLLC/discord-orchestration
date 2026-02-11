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
MY_USER_ID=""  # Cached bot user ID for first-reactor-wins logic
LOST_MESSAGES_FILE="/tmp/discord-workers/${WORKER_ID}-lost-messages.txt"  # Cache messages we've lost on

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
    
    # Ensure lost messages cache directory exists
    mkdir -p "$(dirname "$LOST_MESSAGES_FILE")" 2>/dev/null || true
    
    # Check each message
    while IFS= read -r MSG_ID; do
        [[ -z "$MSG_ID" ]] && continue
        
        # Skip messages we've already lost on
        if [[ -f "$LOST_MESSAGES_FILE" ]] && grep -q "^${MSG_ID}$" "$LOST_MESSAGES_FILE" 2>/dev/null; then
            continue
        fi
        
        # First-reactor-wins: Always try to add reaction, then verify
        # Step 1: Add our ✅ reaction (attempt claim)
        local CLAIM_RESPONSE
        CLAIM_RESPONSE=$(curl -s -X PUT \
            -H "Authorization: Bot ${BOT_TOKEN}" \
            "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL}/messages/${MSG_ID}/reactions/%E2%9C%85/@me" 2>&1)
        
        # If we successfully added reaction, verify we're first (double-check)
        if [[ -z "$CLAIM_RESPONSE" ]]; then
            # Step 2: First check with short jitter
            local JITTER=$((100 + RANDOM % 200))  # 100-300ms
            sleep "0.${JITTER}"
            
            # Get our user ID if not cached
            if [[ -z "$MY_USER_ID" ]]; then
                MY_USER_ID=$(discord_api GET "/users/@me" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
            fi
            
            # Step 3: First verification - check reaction list
            local REACTIONS
            REACTIONS=$(discord_api GET "/channels/${TASK_QUEUE_CHANNEL}/messages/${MSG_ID}/reactions/%E2%9C%85")
            
            local FIRST_REACTOR
            FIRST_REACTOR=$(echo "$REACTIONS" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if data and len(data) > 0:
        print(data[0].get('id', ''))
except:
    pass
" 2>/dev/null)
            
            # Step 4: If not first, we lost
            if [[ -n "$FIRST_REACTOR" && -n "$MY_USER_ID" && "$FIRST_REACTOR" != "$MY_USER_ID" ]]; then
                echo "[$(date '+%H:%M:%S')] Lost race (check 1) for ${MSG_ID:0:12}... (first: ${FIRST_REACTOR:0:12}, me: ${MY_USER_ID:0:12}), caching" >&2
                echo "$MSG_ID" >> "$LOST_MESSAGES_FILE"
                continue
            fi
            
            # Step 5: Double-check verification - wait again and re-verify
            # This catches eventual consistency issues in Discord's API
            sleep 0.3
            
            local REACTIONS2
            REACTIONS2=$(discord_api GET "/channels/${TASK_QUEUE_CHANNEL}/messages/${MSG_ID}/reactions/%E2%9C%85")
            
            local FIRST_REACTOR2
            FIRST_REACTOR2=$(echo "$REACTIONS2" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if data and len(data) > 0:
        print(data[0].get('id', ''))
except:
    pass
" 2>/dev/null)
            
            # Step 6: Second verification - if not first, we lost
            if [[ -n "$FIRST_REACTOR2" && -n "$MY_USER_ID" && "$FIRST_REACTOR2" != "$MY_USER_ID" ]]; then
                echo "[$(date '+%H:%M:%S')] Lost race (check 2) for ${MSG_ID:0:12}... (first: ${FIRST_REACTOR2:0:12}, me: ${MY_USER_ID:0:12}), caching" >&2
                echo "$MSG_ID" >> "$LOST_MESSAGES_FILE"
                continue
            fi
            
            # Step 6: We won! Get message content and return task
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
    
    # Check if agent config specified
    AGENT_CONFIG="${AGENT_CONFIG:-}"
    
    # Local agent always uses default model from config
    # Get actual default model
    DEFAULT_MODEL=$(cat ~/.openclaw/openclaw.json 2>/dev/null | grep '"primary"' | cut -d'"' -f4 || echo "unknown")
    MODEL="${DEFAULT_MODEL:-openrouter/moonshotai/kimi-k2.5}"
    
    if [[ "$REQUESTED_MODEL" != "$MODEL" ]]; then
        echo "[$(date '+%H:%M:%S')] ℹ️ Requested '$REQUESTED_MODEL' but local agent uses default: $MODEL"
    fi
    
    # Export so parent scope can see actual model used
    export MODEL
    
    echo "[$(date '+%H:%M:%S')] Executing: ${TASK_DESC:0:50}..."
    echo "[$(date '+%H:%M:%S')] Using model: $MODEL"
    [[ -n "$AGENT_CONFIG" ]] && echo "[$(date '+%H:%M:%S')] Using agent config: $AGENT_CONFIG"
    
    # Gateway-attached worker: uses OpenClaw default workspace (no sandbox)
    # Workers now have full filesystem access like standard OpenClaw agents
    local WORKSPACE="$HOME/.openclaw/workspace"
    local TASK_DIR="${WORKSPACE}/worker-${WORKER_ID}-${TASK_ID}"
    
    # Create task subfolder for outputs
    mkdir -p "$TASK_DIR"
    
    # IMPORTANT: openclaw agent always uses root workspace, so we write task files there
    # Backup any existing AGENTS.md first
    if [[ -f "${WORKSPACE}/AGENTS.md" ]]; then
        mv "${WORKSPACE}/AGENTS.md" "${WORKSPACE}/AGENTS.md.backup.$$" 2>/dev/null || true
    fi
    
    cat > "${WORKSPACE}/AGENTS.md" << EOF
# Worker ${WORKER_ID}
Task: ${TASK_DESC}
Write result to RESULT.txt
EOF

    cat > "${WORKSPACE}/TASK.txt" << EOF
TASK: ${TASK_DESC}
EOF

    # Also copy to task dir for reference
    cp "${WORKSPACE}/AGENTS.md" "${WORKSPACE}/TASK.txt" "$TASK_DIR/"
    
    cd "$TASK_DIR"
    
    # Gateway-attached agent (no --local flag) - full filesystem access
    # Build agent command with optional agent config for model selection
    local AGENT_CMD="openclaw agent --session-id ${WORKER_ID}-${TASK_ID}"
    
    # Add agent config if specified (for cheap/smart/coding/research workers)
    if [[ -n "$AGENT_CONFIG" ]]; then
        AGENT_CMD="${AGENT_CMD} --agent ${AGENT_CONFIG}"
        echo "[$(date '+%H:%M:%S')] Using agent: ${AGENT_CONFIG}"
    fi
    
    AGENT_CMD="${AGENT_CMD} --message \"Complete the task in TASK.txt. Write result to RESULT.txt in ${TASK_DIR}/\" --thinking ${THINKING}"
    
    if timeout 120 bash -c "$AGENT_CMD" > agent-output.log 2>&1; then
        
        # Check for RESULT.txt in task dir (agent may write it there if instructed)
        # or in root workspace (default behavior)
        if [[ -f "${TASK_DIR}/RESULT.txt" ]]; then
            return 0
        elif [[ -f "${WORKSPACE}/RESULT.txt" ]]; then
            cp "${WORKSPACE}/RESULT.txt" "${TASK_DIR}/RESULT.txt"
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
    local TASK_DESC=$(echo "$TASK_DATA" | cut -d'|' -f2)
    
    # Updated path for non-sandboxed (gateway-attached) workers
    # Try task dir first, fallback to root workspace
    local RESULT_FILE="$HOME/.openclaw/workspace/worker-${WORKER_ID}-${TASK_ID}/RESULT.txt"
    [[ ! -f "$RESULT_FILE" ]] && RESULT_FILE="$HOME/.openclaw/workspace/RESULT.txt"
    local RESULT=""
    [[ -f "$RESULT_FILE" ]] && RESULT=$(cat "$RESULT_FILE" 2>/dev/null)
    
    # Local log with full details
    echo "${TASK_ID}|${WORKER_ID}|${STATUS}|$(date +%s)|${MODEL}|${THINKING}|${TOKENS_IN}|${TOKENS_OUT}|${RESULT:0:300}" >> /tmp/discord-tasks/results.txt
    
    # Build debug info with task details
    local WORKSPACE_DIR="$HOME/.openclaw/workspace/worker-${WORKER_ID}-${TASK_ID}"
    local DEBUG_INFO=""
    
    # List modified files in workspace
    if [[ -d "$WORKSPACE_DIR" ]]; then
        local FILES=$(ls -1 "$WORKSPACE_DIR" 2>/dev/null | head -10 | tr '\n' ', ')
        [[ -n "$FILES" ]] && DEBUG_INFO="\n**Files:** ${FILES%, }"
    fi
    
    # Discord message with enhanced info and full details
    # Use 3 backticks for proper Discord code block rendering
    local MSG="**[${STATUS}]** \`${TASK_ID}\` by **${WORKER_ID}**
**Model:** ${MODEL} | **Thinking:** ${THINKING} | **Tokens:** ${TOKENS_IN} in / ${TOKENS_OUT} out

**Task Prompt:**
\`\`\`
${TASK_DESC:0:500}
${TASK_DESC:500:+... (truncated)}
\`\`\`

**Result:**
\`\`\`
${RESULT:0:800}
\`\`\`${DEBUG_INFO}

📁 **Workspace:** \`${WORKSPACE_DIR}\`"
    
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
echo "[$(date '+%H:%M:%S')] Worker ${WORKER_ID} starting (gateway-attached, full filesystem access)..."
post_status "READY" "Online and waiting (non-sandboxed)"

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
        
        post_status "CLAIMED" "Task ID: ${TASK%%|*} | Model: ${TASK_MODEL} | Thinking: ${TASK_THINKING}"
        
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
            
            post_result "SUCCESS" "$TASK" "$MODEL" "$TASK_THINKING" "$TOKENS_IN" "$TOKENS_OUT"
        else
            post_result "FAILED" "$TASK" "$MODEL" "$TASK_THINKING" "N/A" "N/A"
        fi
        
        post_status "RESTARTING" "Task complete"
        exit 0
    fi
    
    sleep $POLL_INTERVAL
    IDLE_TIME=$((IDLE_TIME + POLL_INTERVAL))
done

post_status "IDLE" "Timeout after ${MAX_IDLE_TIME}s"
exit 0
