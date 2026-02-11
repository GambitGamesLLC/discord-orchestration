#!/bin/bash
#
# worker-reaction.sh - Discord-based task claiming worker

set -euo pipefail

# Get script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Auto-create workers output directory if it doesn't exist
WORKERS_DIR="${PROJECT_DIR}/workers"
mkdir -p "$WORKERS_DIR"

WORKER_ID="${WORKER_ID:-worker-unknown}"
BOT_TOKEN="${BOT_TOKEN:-}"
TASK_QUEUE_CHANNEL="${TASK_QUEUE_CHANNEL:-}"
RESULTS_CHANNEL="${RESULTS_CHANNEL:-}"
WORKER_POOL_CHANNEL="${WORKER_POOL_CHANNEL:-}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
MAX_IDLE_TIME="${MAX_IDLE_TIME:-300}"
MY_USER_ID=""  # Cached bot user ID for first-reactor-wins logic
# Cache files for race losses and completed tasks (in /tmp for temp storage)
LOST_MESSAGES_FILE="/tmp/discord-workers/${WORKER_ID}-lost-messages.txt"
COMPLETED_MESSAGES_FILE="/tmp/discord-workers/${WORKER_ID}-completed-messages.txt"

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
        
        # Skip messages we've already completed (prevent re-claiming after restart)
        if [[ -f "$COMPLETED_MESSAGES_FILE" ]] && grep -q "^${MSG_ID}$" "$COMPLETED_MESSAGES_FILE" 2>/dev/null; then
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
    
    # Configurable workspace - defaults to workers/ subdir in project
    # Workers use isolated directory to prevent config corruption
    local WORKSPACE="${WORKER_WORKSPACE:-$WORKERS_DIR}"
    local TASK_DIR="${WORKSPACE}/worker-${WORKER_ID}-${TASK_ID}"
    # OpenClaw still needs its config from default location
    local OPENCLAW_WORKSPACE="$HOME/.openclaw/workspace"
    
    # Create task subfolder for outputs (isolated from .openclaw/)
    mkdir -p "$TASK_DIR"
    
    # OpenClaw agent reads from its default workspace, so write task files there
    # But keep all worker outputs in isolated TASK_DIR
    # Backup any existing AGENTS.md first
    if [[ -f "${OPENCLAW_WORKSPACE}/AGENTS.md" ]]; then
        mv "${OPENCLAW_WORKSPACE}/AGENTS.md" "${OPENCLAW_WORKSPACE}/AGENTS.md.backup.$$" 2>/dev/null || true
    fi
    
    cat > "${OPENCLAW_WORKSPACE}/AGENTS.md" << EOF
# Worker ${WORKER_ID}
Task: ${TASK_DESC}
Write result to RESULT.txt
EOF

    cat > "${OPENCLAW_WORKSPACE}/TASK.txt" << EOF
TASK: ${TASK_DESC}
EOF

    # Copy task files to isolated dir for reference
    cp "${OPENCLAW_WORKSPACE}/AGENTS.md" "${OPENCLAW_WORKSPACE}/TASK.txt" "$TASK_DIR/"
    
    cd "$TASK_DIR"
    
    # Gateway-attached agent (no --local flag) - full filesystem access
    # Build agent command with model override support
    local AGENT_CMD="openclaw agent --session-id ${WORKER_ID}-${TASK_ID}"
    
    # Map model aliases to full model names for OpenClaw
    local MODEL_FLAG=""
    case "$REQUESTED_MODEL" in
        "cheap"|"step-3.5-flash:free")
            MODEL_FLAG="openrouter/stepfun/step-3.5-flash:free"
            ;;
        "coder"|"qwen3-coder-next")
            MODEL_FLAG="openrouter/qwen/qwen3-coder-next"
            ;;
        "research"|"gemini-3-pro-preview")
            MODEL_FLAG="openrouter/google/gemini-3-pro-preview"
            ;;
        "primary"|"kimi-k2.5")
            MODEL_FLAG="openrouter/moonshotai/kimi-k2.5"
            ;;
        openrouter/*)
            # Full model path provided
            MODEL_FLAG="$REQUESTED_MODEL"
            ;;
        *)
            # Default to primary if unrecognized
            MODEL_FLAG="$MODEL"
            ;;
    esac
    
    # For OpenClaw gateway mode, model is set via OPENCLAW_MODEL env var
    # (openclaw agent doesn't have a --model flag, it uses env or config)
    if [[ -n "$MODEL_FLAG" && "$MODEL_FLAG" != "$MODEL" ]]; then
        export OPENCLAW_MODEL="$MODEL_FLAG"
        MODEL="$MODEL_FLAG"
        echo "[$(date '+%H:%M:%S')] Using requested model: $MODEL_FLAG"
    fi
    
    # Add agent config if specified (optional, for complex agent setups)
    if [[ -n "$AGENT_CONFIG" ]]; then
        AGENT_CMD="${AGENT_CMD} --agent ${AGENT_CONFIG}"
        echo "[$(date '+%H:%M:%S')] Using agent config: ${AGENT_CONFIG}"
    fi
    
    AGENT_CMD="${AGENT_CMD} --message \"Complete the task in TASK.txt. Write result to RESULT.txt in ${TASK_DIR}/\" --thinking ${THINKING}"
    
    if timeout 120 bash -c "$AGENT_CMD" > agent-output.log 2>&1; then
        
        # Check for RESULT.txt in isolated task dir first (preferred)
        # Fallback to openclaw workspace if agent wrote there
        if [[ -f "${TASK_DIR}/RESULT.txt" ]]; then
            return 0
        elif [[ -f "${OPENCLAW_WORKSPACE}/RESULT.txt" ]]; then
            cp "${OPENCLAW_WORKSPACE}/RESULT.txt" "${TASK_DIR}/RESULT.txt"
            rm "${OPENCLAW_WORKSPACE}/RESULT.txt"  # Clean up after copying
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
    
    # Use project workers directory (auto-created at startup)
    local WORKSPACE="${WORKER_WORKSPACE:-$WORKERS_DIR}"
    local RESULT_FILE="${WORKSPACE}/worker-${WORKER_ID}-${TASK_ID}/RESULT.txt"
    # Fallback to openclaw workspace if needed
    [[ ! -f "$RESULT_FILE" ]] && RESULT_FILE="$HOME/.openclaw/workspace/RESULT.txt"
    local RESULT=""
    [[ -f "$RESULT_FILE" ]] && RESULT=$(cat "$RESULT_FILE" 2>/dev/null)
    
    # Local log with full details
    echo "${TASK_ID}|${WORKER_ID}|${STATUS}|$(date +%s)|${MODEL}|${THINKING}|${TOKENS_IN}|${TOKENS_OUT}|${RESULT:0:300}" >> /tmp/discord-tasks/results.txt
    
    # Build debug info with task details
    local WORKSPACE_DIR="${WORKSPACE}/worker-${WORKER_ID}-${TASK_ID}"
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
        
        # Cache this task as completed to prevent re-claiming after restart
        # Extract Discord message ID from task (format: discord-<MSG_ID>|<desc>|...)
        local COMPLETED_MSG_ID=$(echo "$TASK" | cut -d'|' -f1 | sed 's/^discord-//')
        if [[ -n "$COMPLETED_MSG_ID" ]]; then
            mkdir -p "$(dirname "$COMPLETED_MESSAGES_FILE")" 2>/dev/null || true
            echo "$COMPLETED_MSG_ID" >> "$COMPLETED_MESSAGES_FILE"
            echo "[$(date '+%H:%M:%S')] Cached completed task: ${COMPLETED_MSG_ID:0:12}..."
        fi
        
        post_status "RESTARTING" "Task complete"
        exit 0
    fi
    
    sleep $POLL_INTERVAL
    IDLE_TIME=$((IDLE_TIME + POLL_INTERVAL))
done

post_status "IDLE" "Timeout after ${MAX_IDLE_TIME}s"
exit 0
