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
# Add randomized poll interval per worker
# This desynchronizes workers to reduce race conditions
randomize_poll_interval() {
    # Random interval between 3-8 seconds (was fixed 5s)
    export POLL_INTERVAL=$(( 3 + RANDOM % 6 ))
    echo "[$(date '+%H:%M:%S')] Worker ${WORKER_ID} using poll interval: ${POLL_INTERVAL}s"
}

# Call at startup
randomize_poll_interval
MAX_IDLE_TIME="${MAX_IDLE_TIME:-300}"
MY_USER_ID=""  # Cached bot user ID for first-reactor-wins logic

# Cache files for race losses and completed tasks (inside repo, gitignored)
# This ensures persistence across worker restarts but not system reboots
RUNTIME_DIR="${PROJECT_DIR}/.runtime"
LOST_MESSAGES_FILE="${RUNTIME_DIR}/${WORKER_ID}-lost-messages.txt"
COMPLETED_MESSAGES_FILE="${RUNTIME_DIR}/${WORKER_ID}-completed-messages.txt"
mkdir -p "$RUNTIME_DIR" 2>/dev/null || true

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
    
    # Get our user ID for reaction checking
    if [[ -z "$MY_USER_ID" ]]; then
        MY_USER_ID=$(discord_api GET "/users/@me" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
    fi
    
    # Ensure cache directories exist
    mkdir -p "$(dirname "$LOST_MESSAGES_FILE")" 2>/dev/null || true
    mkdir -p "$(dirname "$COMPLETED_MESSAGES_FILE")" 2>/dev/null || true
    
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
        
        # BUGFIX: Skip messages that already have ANY ✅ reaction (already claimed)
        # This prevents the infinite loop where we keep picking up our own completed tasks
        local EXISTING_REACTIONS
        EXISTING_REACTIONS=$(discord_api GET "/channels/${TASK_QUEUE_CHANNEL}/messages/${MSG_ID}/reactions/%E2%9C%85")
        
        local REACTION_COUNT
        REACTION_COUNT=$(echo "$EXISTING_REACTIONS" | python3 -c "import json,sys; data=json.load(sys.stdin); print(len(data) if isinstance(data, list) else 0)" 2>/dev/null)
        
        if [[ "${REACTION_COUNT:-0}" -gt 0 ]]; then
            # Check if we're the one who reacted (we already processed this)
            local HAS_MY_REACTION
            HAS_MY_REACTION=$(echo "$EXISTING_REACTIONS" | python3 -c "import json,sys; data=json.load(sys.stdin); ids=[u.get('id','') for u in data]; print('yes' if '${MY_USER_ID}' in ids else 'no')" 2>/dev/null)
            
            if [[ "$HAS_MY_REACTION" == "yes" ]]; then
                # We already have a reaction on this message - we must have processed it before
                echo "[$(date '+%H:%M:%S')] Skipping message ${MSG_ID:0:12}... (already has our reaction - completed)" >&2
                echo "$MSG_ID" >> "$COMPLETED_MESSAGES_FILE"
                continue
            else
                # Someone else claimed it
                echo "[$(date '+%H:%M:%S')] Skipping message ${MSG_ID:0:12}... (already claimed by another)" >&2
                echo "$MSG_ID" >> "$LOST_MESSAGES_FILE"
                continue
            fi
        fi
        
        # First-reactor-wins: Try to add reaction, then verify
        # Step 1: Add our ✅ reaction (attempt claim)
        local CLAIM_RESPONSE
        CLAIM_RESPONSE=$(curl -s -X PUT \
            -H "Authorization: Bot ${BOT_TOKEN}" \
            "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL}/messages/${MSG_ID}/reactions/%E2%9C%85/@me" 2>&1)
        
        # If we successfully added reaction, verify we're first (double-check)
        if [[ -z "$CLAIM_RESPONSE" ]]; then
            # Step 2: First check with increased jitter (200-500ms)
            local JITTER=$((200 + RANDOM % 300))  # 200-500ms (increased from 100-300ms)
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
            
            # Check if multiple reactors exist (potential race condition)
            local REACTION_COUNT
            REACTION_COUNT=$(echo "$REACTIONS" | python3 -c "import json,sys; data=json.load(sys.stdin); print(len(data) if isinstance(data, list) else 0)" 2>/dev/null)
            
            # Step 5: If multiple reactors detected, enter exponential backoff loop
            if [[ "${REACTION_COUNT:-0}" -gt 1 ]]; then
                echo "[$(date '+%H:%M:%S')] Multiple reactors detected (${REACTION_COUNT}), entering exponential backoff..." >&2
                
                # Exponential backoff: 4 attempts with increasing delays
                # Formula: delay_ms = 100 * (2 ^ attempt) + random(0-100)
                for attempt in 0 1 2 3; do
                    local DELAY_MS=$(( 100 * (2 ** attempt) + RANDOM % 100 ))
                    echo "[$(date '+%H:%M:%S')] Backoff attempt ${attempt}: waiting ${DELAY_MS}ms..." >&2
                    sleep "0.${DELAY_MS}"
                    
                    # Re-check reactions
                    local BACKOFF_REACTIONS
                    BACKOFF_REACTIONS=$(discord_api GET "/channels/${TASK_QUEUE_CHANNEL}/messages/${MSG_ID}/reactions/%E2%9C%85")
                    
                    local BACKOFF_FIRST_REACTOR
                    BACKOFF_FIRST_REACTOR=$(echo "$BACKOFF_REACTIONS" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if data and len(data) > 0:
        print(data[0].get('id', ''))
except:
    pass
" 2>/dev/null)
                    
                    # Check if we're still first
                    if [[ -n "$BACKOFF_FIRST_REACTOR" && -n "$MY_USER_ID" && "$BACKOFF_FIRST_REACTOR" != "$MY_USER_ID" ]]; then
                        echo "[$(date '+%H:%M:%S')] Lost race after backoff attempt ${attempt} for ${MSG_ID:0:12}... (first: ${BACKOFF_FIRST_REACTOR:0:12}, me: ${MY_USER_ID:0:12}), caching" >&2
                        echo "$MSG_ID" >> "$LOST_MESSAGES_FILE"
                        continue 2  # Continue to next message
                    fi
                    
                    # If we're still first, continue to next backoff attempt
                done
                
                echo "[$(date '+%H:%M:%S')] Passed all backoff checks successfully!" >&2
            fi
            
            # Step 6: Final verification with increased delay (500ms instead of 300ms)
            sleep 0.5  # Increased from 0.3
            
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
            
            # Step 7: Second verification - if not first, we lost
            if [[ -n "$FIRST_REACTOR2" && -n "$MY_USER_ID" && "$FIRST_REACTOR2" != "$MY_USER_ID" ]]; then
                echo "[$(date '+%H:%M:%S')] Lost race (check 2) for ${MSG_ID:0:12}... (first: ${FIRST_REACTOR2:0:12}, me: ${MY_USER_ID:0:12}), caching" >&2
                echo "$MSG_ID" >> "$LOST_MESSAGES_FILE"
                continue
            fi
            
            # Step 8: We won! Get message content and return task
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
    local QUEUE_FILE="${RUNTIME_DIR}/queue.txt"
    local CLAIMED_FILE="${RUNTIME_DIR}/claimed.txt"
    local LOCK_FILE="${RUNTIME_DIR}/queue.lock"
    
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

# Setup isolated worker state directory
setup_worker_state() {
    local WORKER_STATE_DIR="${WORKERS_DIR}/${WORKER_ID}"
    
    # Create worker state directory
    mkdir -p "$WORKER_STATE_DIR"
    
    # Only write AGENTS.md if task context is provided
    if [[ -n "$TASK_DESC" ]]; then
        cat > "${WORKER_STATE_DIR}/AGENTS.md" << EOF
# Worker ${WORKER_ID}

## Task
${TASK_DESC}

## Model Defaults
- Primary: openrouter/moonshotai/kimi-k2.5
- Cheap: openrouter/stepfun/step-3.5-flash:free
- Coder: openrouter/qwen/qwen3-coder-next
- Research: openrouter/google/gemini-3-pro-preview

## Output
Write result to RESULT.txt
EOF
    fi
    
    # Copy TOOLS.md if it exists (for env-specific tools)
    if [[ -f "${WORKERS_DIR}/TOOLS.md" ]]; then
        cp "${WORKERS_DIR}/TOOLS.md" "${WORKER_STATE_DIR}/TOOLS.md"
    fi
    
    # Export OPENCLAW_STATE_DIR for isolated worker state
    export OPENCLAW_STATE_DIR="${WORKER_STATE_DIR}"
}

execute_task() {
    local TASK_DATA="$1"
    local TASK_ID=$(echo "$TASK_DATA" | cut -d'|' -f1)
    local TASK_DESC=$(echo "$TASK_DATA" | cut -d'|' -f2)
    local REQUESTED_MODEL=$(echo "$TASK_DATA" | cut -d'|' -f3)
    local THINKING=$(echo "$TASK_DATA" | cut -d'|' -f4)
    
    # Check if agent config specified
    AGENT_CONFIG="${AGENT_CONFIG:-}"
    
    # Default model (defined in AGENTS.md, kept here for reference)
    MODEL="openrouter/moonshotai/kimi-k2.5"
    
    if [[ "$REQUESTED_MODEL" != "$MODEL" ]]; then
        echo "[$(date '+%H:%M:%S')] ℹ️ Requested '$REQUESTED_MODEL' but local agent uses default: $MODEL"
    fi
    
    # Export so parent scope can see actual model used
    export MODEL
    
    echo "[$(date '+%H:%M:%S')] Executing: ${TASK_DESC:0:50}..."
    echo "[$(date '+%H:%M:%S')] Using model: $MODEL"
    [[ -n "$AGENT_CONFIG" ]] && echo "[$(date '+%H:%M:%S')] Using agent config: $AGENT_CONFIG"
    
    # Setup isolated worker state directory using OPENCLAW_STATE_DIR
    setup_worker_state
    
    # Task output directory (inside worker state)
    local WORKER_STATE_DIR="${WORKERS_DIR}/${WORKER_ID}"
    local TASK_DIR="${WORKER_STATE_DIR}/tasks/${TASK_ID}"
    
    # Create task subfolder for outputs
    mkdir -p "$TASK_DIR"
    
    # Write task context to isolated task directory
    cat > "${TASK_DIR}/TASK.txt" << EOF
TASK: ${TASK_DESC}
EOF

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
    
    # Update MODEL to the resolved model for correct reporting
    MODEL="$MODEL_FLAG"
    
    # For OpenClaw gateway mode, model is set via OPENCLAW_MODEL env var
    # (openclaw agent doesn't have a --model flag, it uses env or config)
    if [[ -n "$MODEL_FLAG" ]]; then
        export OPENCLAW_MODEL="$MODEL_FLAG"
        echo "[$(date '+%H:%M:%S')] Using requested model: $MODEL_FLAG"
    fi
    
    # Add agent config if specified (optional, for complex agent setups)
    if [[ -n "$AGENT_CONFIG" ]]; then
        AGENT_CMD="${AGENT_CMD} --agent ${AGENT_CONFIG}"
        echo "[$(date '+%H:%M:%S')] Using agent config: ${AGENT_CONFIG}"
    fi
    
    AGENT_CMD="${AGENT_CMD} --message \"Complete the task in TASK.txt. Write result to RESULT.txt in ${TASK_DIR}/\" --thinking ${THINKING}"
    
    # Export tokens so post_result can access them
    export TOKENS_IN="unknown"
    export TOKENS_OUT="unknown"
    
    # Run agent (don't exit on error - we still want to extract tokens)
    timeout 120 bash -c "$AGENT_CMD" > agent-output.log 2>&1 || true
    
    # ALWAYS try to extract tokens from session file (even if agent timed out)
    local SESSION_FILE="${HOME}/.openclaw/agents/main/sessions/${WORKER_ID}-${TASK_ID}.jsonl"
    if [[ -f "$SESSION_FILE" ]]; then
        local TOKENS_JSON
        TOKENS_JSON=$(tail -20 "$SESSION_FILE" 2>/dev/null | python3 -c "
import json,sys
usage = None
for line in sys.stdin:
    try:
        data = json.loads(line)
        if data.get('type') == 'message' and data.get('message',{}).get('role') == 'assistant':
            msg = data['message']
            if 'usage' in msg:
                usage = msg['usage']
    except:
        pass
if usage:
    print(json.dumps(usage))
" 2>/dev/null) || true
        
        if [[ -n "$TOKENS_JSON" ]]; then
            TOKENS_IN=$(echo "$TOKENS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('input', 'unknown'))" 2>/dev/null || echo "unknown")
            TOKENS_OUT=$(echo "$TOKENS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('output', 'unknown'))" 2>/dev/null || echo "unknown")
            echo "[$(date '+%H:%M:%S')] Extracted tokens: in=${TOKENS_IN}, out=${TOKENS_OUT}"
            
            # Calculate cost
            export COST="N/A"
            if [[ "$TOKENS_IN" != "unknown" && "$TOKENS_OUT" != "unknown" ]]; then
                local CONFIG_FILE="${HOME}/.openclaw/openclaw.json"
                if [[ -f "$CONFIG_FILE" ]]; then
                    # Strip 'openrouter/' prefix if present (config stores model IDs without prefix)
                    local MODEL_ID="${MODEL#openrouter/}"
                    local INPUT_COST=$(jq -r --arg model "$MODEL_ID" '.models.providers.openrouter.models[] | select(.id == $model) | .cost.input' "$CONFIG_FILE" 2>/dev/null || echo "0")
                    local OUTPUT_COST=$(jq -r --arg model "$MODEL_ID" '.models.providers.openrouter.models[] | select(.id == $model) | .cost.output' "$CONFIG_FILE" 2>/dev/null || echo "0")
                    
                    if [[ "$INPUT_COST" != "null" && "$OUTPUT_COST" != "null" && "$INPUT_COST" != "" ]]; then
                        COST=$(echo "scale=6; ($TOKENS_IN * $INPUT_COST + $TOKENS_OUT * $OUTPUT_COST) / 1000" | bc 2>/dev/null || echo "N/A")
                        echo "[$(date '+%H:%M:%S')] Calculated cost: \${COST}"
                    fi
                fi
            fi
            export COST
        fi
    fi
    
    # Check for RESULT.txt - success if it exists (regardless of agent exit code)
    if [[ -f "${TASK_DIR}/RESULT.txt" ]]; then
        return 0
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
    local COST="${COST:-N/A}"
    
    local TASK_ID=$(echo "$TASK_DATA" | cut -d'|' -f1)
    local TASK_DESC=$(echo "$TASK_DATA" | cut -d'|' -f2)
    
    # Use project workers directory (auto-created at startup)
    local WORKER_STATE_DIR="${WORKERS_DIR}/${WORKER_ID}"
    local RESULT_FILE="${WORKER_STATE_DIR}/tasks/${TASK_ID}/RESULT.txt"
    local RESULT=""
    [[ -f "$RESULT_FILE" ]] && RESULT=$(cat "$RESULT_FILE" 2>/dev/null)
    
    # Use COST from execute_task (already calculated and exported)
    # Fall back to local calculation if not set
    if [[ "${COST:-N/A}" == "N/A" && "$TOKENS_IN" != "unknown" && "$TOKENS_OUT" != "unknown" ]]; then
        local CONFIG_FILE="${HOME}/.openclaw/openclaw.json"
        if [[ -f "$CONFIG_FILE" ]]; then
            # Strip 'openrouter/' prefix if present (config stores model IDs without prefix)
            local MODEL_ID="${MODEL#openrouter/}"
            # Extract cost per 1K tokens for the model from config
            local INPUT_COST=$(jq -r --arg model "$MODEL_ID" '.models.providers.openrouter.models[] | select(.id == $model) | .cost.input' "$CONFIG_FILE" 2>/dev/null || echo "0")
            local OUTPUT_COST=$(jq -r --arg model "$MODEL_ID" '.models.providers.openrouter.models[] | select(.id == $model) | .cost.output' "$CONFIG_FILE" 2>/dev/null || echo "0")
            
            if [[ "$INPUT_COST" != "null" && "$OUTPUT_COST" != "null" && "$INPUT_COST" != "" ]]; then
                # Calculate: (tokens / 1000) * cost_per_1k
                COST=$(echo "scale=6; ($TOKENS_IN * $INPUT_COST + $TOKENS_OUT * $OUTPUT_COST) / 1000" | bc 2>/dev/null || echo "N/A")
            fi
        fi
    fi
    # Ensure COST is set for logging
    COST="${COST:-N/A}"
    
    # Local log with full details
    mkdir -p "${RUNTIME_DIR}" 2>/dev/null || true
    echo "${TASK_ID}|${WORKER_ID}|${STATUS}|$(date +%s)|${MODEL}|${THINKING}|${TOKENS_IN}|${TOKENS_OUT}|${COST}|${RESULT:0:300}" >> "${RUNTIME_DIR}/results.txt"
    
    # Build debug info with task details
    local WORKSPACE_DIR="${WORKER_STATE_DIR}/tasks/${TASK_ID}"
    local DEBUG_INFO=""
    
    # List modified files in workspace
    if [[ -d "$WORKSPACE_DIR" ]]; then
        local FILES=$(ls -1 "$WORKSPACE_DIR" 2>/dev/null | head -10 | tr '\n' ', ')
        [[ -n "$FILES" ]] && DEBUG_INFO="\n**Files:** ${FILES%, }"
    fi
    
    # Discord message with enhanced info and full details
    # Use 3 backticks for proper Discord code block rendering
    # Add visual separator at start to separate from previous messages
    local MSG="═══════════════════════════════════════

**[${STATUS}]** \`${TASK_ID}\` by **${WORKER_ID}**
**Model:** ${MODEL} | **Thinking:** ${THINKING} | **Tokens:** ${TOKENS_IN} in / ${TOKENS_OUT} out | **Cost:** ${COST}

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
    
    # Post to Discord with error handling (don't crash if Discord fails)
    if ! post_to_discord "$RESULTS_CHANNEL" "$MSG" 2>/dev/null; then
        echo "[$(date '+%H:%M:%S')] ⚠️ Failed to post to Discord #results, but task completed successfully" >&2
    fi
}

post_status() {
    local STATUS="$1"
    local MSG="$2"
    echo "[STATUS] ${WORKER_ID}: ${STATUS}"
    mkdir -p "${RUNTIME_DIR}" 2>/dev/null || true
    echo "$(date +%s)|${WORKER_ID}|${STATUS}|${MSG}" >> "${RUNTIME_DIR}/status.txt"
    post_to_discord "$WORKER_POOL_CHANNEL" "**[${STATUS}]** ${WORKER_ID}: ${MSG}"
}

# Main
echo "[$(date '+%H:%M:%S')] Worker ${WORKER_ID} starting (gateway-attached, full filesystem access)..."
post_status "READY" "Online and waiting (non-sandboxed)" || true

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
        
        post_status "CLAIMED" "Task ID: ${TASK%%|*} | Model: ${TASK_MODEL} | Thinking: ${TASK_THINKING}" || true
        
        # Execute task with error handling
        if execute_task "$TASK"; then
            # Tokens are already extracted in execute_task and exported
            # Log locally first (always works)
            echo "${TASK%%|*}|${WORKER_ID}|SUCCESS|$(date +%s)|${MODEL}|${TASK_THINKING}|${TOKENS_IN:-unknown}|${TOKENS_OUT:-unknown}|Task completed" >> "${RUNTIME_DIR}/results.txt"
            # Then try to post to Discord
            post_result "SUCCESS" "$TASK" "$MODEL" "$TASK_THINKING" "$TOKENS_IN" "$TOKENS_OUT" || true
        else
            # Log failure locally
            echo "${TASK%%|*}|${WORKER_ID}|FAILED|$(date +%s)|${MODEL}|${TASK_THINKING}|N/A|N/A|Task execution failed" >> "${RUNTIME_DIR}/results.txt"
            post_result "FAILED" "$TASK" "$MODEL" "$TASK_THINKING" "N/A" "N/A" || true
        fi
        
        # Cache this task as completed to prevent re-claiming after restart
        # Extract Discord message ID from task (format: discord-<MSG_ID>|<desc>|...)
        COMPLETED_MSG_ID=$(echo "$TASK" | cut -d'|' -f1 | sed 's/^discord-//')
        if [[ -n "$COMPLETED_MSG_ID" ]]; then
            mkdir -p "$(dirname "$COMPLETED_MESSAGES_FILE")" 2>/dev/null || true
            echo "$COMPLETED_MSG_ID" >> "$COMPLETED_MESSAGES_FILE"
            echo "[$(date '+%H:%M:%S')] Cached completed task: ${COMPLETED_MSG_ID:0:12}..."
        fi
        
        post_status "RESTARTING" "Task complete" || true
        exit 0
    fi
    
    sleep $POLL_INTERVAL
    IDLE_TIME=$((IDLE_TIME + POLL_INTERVAL))
done

post_status "IDLE" "Timeout after ${MAX_IDLE_TIME}s"
exit 0
