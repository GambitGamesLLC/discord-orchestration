#!/bin/bash
#
# orchestrator-dynamic.sh - Dynamic agent spawning orchestrator
# Spawns fresh workers per task (like old workers but dynamically)

set -euo pipefail

# Check for jq dependency
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed. Install with: sudo apt-get install jq (Debian/Ubuntu) or brew install jq (macOS)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load config
if [[ -f "${REPO_DIR}/discord-config.env" ]]; then
    source "${REPO_DIR}/discord-config.env"
fi

BOT_TOKEN="${ORCHESTRATOR_AGENT_TOKEN:-}"
TASK_QUEUE_CHANNEL="${TASK_QUEUE_CHANNEL:-}"
RESULTS_CHANNEL="${RESULTS_CHANNEL:-}"
WORKER_POOL_CHANNEL="${WORKER_POOL_CHANNEL:-}"

# Runtime tracking
RUNTIME_DIR="${REPO_DIR}/.runtime"
ASSIGNED_FILE="${RUNTIME_DIR}/assigned-tasks.txt"
mkdir -p "$RUNTIME_DIR"

WORKERS_DIR="${REPO_DIR}/workers"
mkdir -p "$WORKERS_DIR"

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

# Get unassigned tasks
get_pending_tasks() {
    local MESSAGES
    MESSAGES=$(discord_api GET "/channels/${TASK_QUEUE_CHANNEL}/messages?limit=20")
    
    [[ -z "$MESSAGES" ]] && return 0
    
    echo "$MESSAGES" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for msg in data:
    reacts = msg.get('reactions', [])
    has_claim = any(r.get('emoji', {}).get('name') == '✅' for r in reacts)
    if not has_claim:
        print(f\"{msg['id']}|{msg['content'][:500]}\")
" 2>/dev/null | head -10
}

# Mark task as assigned
mark_assigned() {
    local TASK_ID="$1"
    echo "$TASK_ID" >> "$ASSIGNED_FILE"
    discord_api PUT "/channels/${TASK_QUEUE_CHANNEL}/messages/${TASK_ID}/reactions/%E2%9C%85/@me" > /dev/null 2>&1 || true
}

# Check if already assigned
is_assigned() {
    local TASK_ID="$1"
    
    if [[ -f "$ASSIGNED_FILE" ]] && grep -q "^${TASK_ID}$" "$ASSIGNED_FILE" 2>/dev/null; then
        return 0
    fi
    
    local REACTIONS
    REACTIONS=$(discord_api GET "/channels/${TASK_QUEUE_CHANNEL}/messages/${TASK_ID}/reactions/%E2%9C%85")
    local COUNT
    COUNT=$(echo "$REACTIONS" | python3 -c "import json,sys; data=json.load(sys.stdin); print(len(data) if isinstance(data, list) else 0)" 2>/dev/null)
    
    if [[ "${COUNT:-0}" -gt 0 ]]; then
        echo "$TASK_ID" >> "$ASSIGNED_FILE" 2>/dev/null || true
        return 0
    fi
    
    return 1
}

# Parse task details
parse_task() {
    local CONTENT="$1"
    
    local MODEL="primary"
    if [[ "$CONTENT" =~ \[model:([^\]]+)\] ]]; then
        MODEL="${BASH_REMATCH[1]}"
    fi
    
    local THINKING="medium"
    if [[ "$CONTENT" =~ \[thinking:([^\]]+)\] ]]; then
        THINKING="${BASH_REMATCH[1]}"
    fi
    
    local DESC="$CONTENT"
    DESC=$(echo "$DESC" | sed 's/\[model:[^]]*\]//g; s/\[thinking:[^]]*\]//g; s/\*\*//g')
    DESC=$(echo "$DESC" | sed 's/^ *//;s/ *$//')
    
    echo "$MODEL|$THINKING|$DESC"
}

# Spawn agent to execute task
spawn_agent() {
    local TASK_ID="$1"
    local MODEL="$2"
    local THINKING="$3"
    local TASK_DESC="$4"
    
    local AGENT_ID="agent-$(date +%s)-${RANDOM}"
    local WORKER_STATE_DIR="${WORKERS_DIR}/${AGENT_ID}"
    local TASK_DIR="${WORKER_STATE_DIR}/tasks/${TASK_ID}"
    
    echo "[$(date '+%H:%M:%S')] Spawning agent for task ${TASK_ID:0:12}..."
    
    # Create workspace (exactly like old workers)
    mkdir -p "$TASK_DIR"
    
    # Map model alias to full name
    local MODEL_FLAG=""
    case "$MODEL" in
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
            MODEL_FLAG="$MODEL"
            ;;
        *)
            MODEL_FLAG="openrouter/moonshotai/kimi-k2.5"
            ;;
    esac
    
    # Write AGENTS.md (EXACT format from old workers)
    cat > "${WORKER_STATE_DIR}/AGENTS.md" << EOF
# ${AGENT_ID}

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
    
    # Copy TOOLS.md if it exists (like old workers)
    if [[ -f "${WORKERS_DIR}/TOOLS.md" ]]; then
        cp "${WORKERS_DIR}/TOOLS.md" "${WORKER_STATE_DIR}/TOOLS.md"
    fi
    
    # Write TASK.txt (like old workers)
    cat > "${TASK_DIR}/TASK.txt" << EOF
TASK: ${TASK_DESC}
EOF
    
    # Post notice (outside subshell so discord_api works)
    discord_api POST "/channels/${WORKER_POOL_CHANNEL}/messages" \
        "{\"content\":\"🤖 **AGENT SPAWNED**\\nTask: ${TASK_DESC:0:60}...\\nAgent: \`${AGENT_ID}\`\"}" > /dev/null 2>&1 || true
    
    # Spawn agent in background (EXACT command from old workers)
    (
        # Export all needed variables for result posting
        export OPENCLAW_MODEL="$MODEL_FLAG"
        export OPENCLAW_STATE_DIR="$WORKER_STATE_DIR"
        export BOT_TOKEN="${BOT_TOKEN}"
        export RESULTS_CHANNEL="${RESULTS_CHANNEL}"
        export WORKER_POOL_CHANNEL="${WORKER_POOL_CHANNEL}"
        export TASK_ID="${TASK_ID}"
        export AGENT_ID="${AGENT_ID}"
        export MODEL_FLAG="${MODEL_FLAG}"
        export THINKING="${THINKING}"
        export TASK_DESC="${TASK_DESC}"
        export TASK_DIR="${TASK_DIR}"
        export WORKER_STATE_DIR="${WORKER_STATE_DIR}"
        export TIMEOUT="${TIMEOUT:-}"  # Pass through custom timeout if set
        
        cd "$TASK_DIR"
        
        # Set timeout: Use passed TIMEOUT, or default based on thinking level
        # Default: 120s for low/medium, 300s for high thinking
        local AGENT_TIMEOUT="${TIMEOUT:-}"
        if [[ -z "$AGENT_TIMEOUT" ]]; then
            if [[ "${THINKING}" == "high" ]]; then
                AGENT_TIMEOUT=300
            else
                AGENT_TIMEOUT=120
            fi
        fi
        
        # Run agent (EXACT command from old workers)
        timeout $AGENT_TIMEOUT openclaw agent \
            --session-id "${AGENT_ID}-${TASK_ID}" \
            --message "Complete the task in TASK.txt. Write result to RESULT.txt in ${TASK_DIR}/" \
            --thinking "${THINKING}" \
            > agent-output.log 2>&1 || true
        
        # Extract tokens from session file
        local TOKENS_IN="unknown"
        local TOKENS_OUT="unknown"
        local COST="N/A"
        
        local SESSION_FILE="${HOME}/.openclaw/agents/main/sessions/${AGENT_ID}-${TASK_ID}.jsonl"
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
                
                # Calculate cost
                if [[ "$TOKENS_IN" != "unknown" && "$TOKENS_OUT" != "unknown" ]]; then
                    local CONFIG_FILE="${HOME}/.openclaw/openclaw.json"
                    if [[ -f "$CONFIG_FILE" ]]; then
                        local MODEL_ID="${MODEL_FLAG#openrouter/}"
                        local INPUT_COST=$(jq -r --arg model "$MODEL_ID" '.models.providers.openrouter.models[] | select(.id == $model) | .cost.input' "$CONFIG_FILE" 2>/dev/null || echo "0")
                        local OUTPUT_COST=$(jq -r --arg model "$MODEL_ID" '.models.providers.openrouter.models[] | select(.id == $model) | .cost.output' "$CONFIG_FILE" 2>/dev/null || echo "0")
                        
                        if [[ "$INPUT_COST" != "null" && "$OUTPUT_COST" != "null" && "$INPUT_COST" != "" ]]; then
                            COST=$(echo "scale=6; ($TOKENS_IN * $INPUT_COST + $TOKENS_OUT * $OUTPUT_COST) / 1000" | bc 2>/dev/null || echo "N/A")
                        fi
                    fi
                fi
            fi
        fi
        
        # Check for result and post to Discord
        # Common retry settings for both success and failure
        local MAX_RETRIES=5
        
        if [[ -f "RESULT.txt" ]]; then
            local RESULT=$(cat RESULT.txt 2>/dev/null)
            
            # Build nicely formatted Discord message (like old system)
            local DISPLAY_COST="${COST:-N/A}"
            
            # List files with proper spacing (comma + space between each)
            local FILES=$(ls -1 "$TASK_DIR" 2>/dev/null | tr '\n' ', ' | sed 's/, $//; s/,/, /g')
            
            # Build message - use actual newlines which jq will handle
            local MSG=$(printf '═══════════════════════════════════════\n\n**[SUCCESS]** `%s` by **%s**\n**Model:** %s | **Thinking:** %s | **Tokens:** %s in / %s out | **Cost:** $%s\n\n**Task Prompt:**\n```\n%s\n```\n\n**Result:**\n```\n%s\n```\n**Files:** %s\n\n📁 **Workspace:** `%s`' \
                "$TASK_ID" "$AGENT_ID" "$MODEL_FLAG" "$THINKING" "$TOKENS_IN" "$TOKENS_OUT" "$DISPLAY_COST" \
                "${TASK_DESC:0:500}" "${RESULT:0:800}" "$FILES" "$TASK_DIR")
            
            # Post to Discord with retry logic (exponential backoff)
            local RETRY_COUNT=0
            local POST_SUCCESS=0
            
            while [[ $RETRY_COUNT -lt $MAX_RETRIES ]] && [[ $POST_SUCCESS -eq 0 ]]; do
                local RESPONSE
                RESPONSE=$(echo '{"content":"PLACEHOLDER"}' | jq --arg msg "$MSG" '.content = $msg' | \
                    curl -s -w "\n%{http_code}" \
                    -X POST \
                    -H "Authorization: Bot ${BOT_TOKEN}" \
                    -H "Content-Type: application/json" \
                    -d @- \
                    "https://discord.com/api/v10/channels/${RESULTS_CHANNEL}/messages" 2>/dev/null)
                
                local HTTP_CODE=$(echo "$RESPONSE" | tail -1)
                
                if [[ "$HTTP_CODE" == "200" ]] || [[ "$HTTP_CODE" == "201" ]]; then
                    POST_SUCCESS=1
                else
                    RETRY_COUNT=$((RETRY_COUNT + 1))
                    local DELAY=$((2 ** RETRY_COUNT))  # Exponential: 2, 4, 8, 16, 32 seconds
                    echo "[$(date '+%H:%M:%S')] Discord post failed (HTTP $HTTP_CODE), retry $RETRY_COUNT/$MAX_RETRIES in ${DELAY}s..." >> agent-output.log
                    sleep $DELAY
                fi
            done
            
            if [[ $POST_SUCCESS -eq 0 ]]; then
                echo "[$(date '+%H:%M:%S')] Failed to post result after $MAX_RETRIES attempts" >> agent-output.log
            fi
        else
            # Post failure with nice formatting
            local FAIL_MSG=$(printf '═══════════════════════════════════════\n\n**[FAILED]** `%s` by **%s**\n**Model:** %s | **Thinking:** %s\n\n**Task:**\n```\n%s\n```\n\n❌ **No result produced**' \
                "$TASK_ID" "$AGENT_ID" "$MODEL_FLAG" "$THINKING" "${TASK_DESC:0:300}")
            
            # Post failure with retry
            local FAIL_RETRY=0
            local FAIL_SUCCESS=0
            while [[ $FAIL_RETRY -lt $MAX_RETRIES ]] && [[ $FAIL_SUCCESS -eq 0 ]]; do
                local FAIL_RESPONSE
                FAIL_RESPONSE=$(echo '{"content":"PLACEHOLDER"}' | jq --arg msg "$FAIL_MSG" '.content = $msg' | \
                    curl -s -w "\n%{http_code}" \
                    -X POST \
                    -H "Authorization: Bot ${BOT_TOKEN}" \
                    -H "Content-Type: application/json" \
                    -d @- \
                    "https://discord.com/api/v10/channels/${RESULTS_CHANNEL}/messages" 2>/dev/null)
                
                local FAIL_HTTP=$(echo "$FAIL_RESPONSE" | tail -1)
                if [[ "$FAIL_HTTP" == "200" ]] || [[ "$FAIL_HTTP" == "201" ]]; then
                    FAIL_SUCCESS=1
                else
                    FAIL_RETRY=$((FAIL_RETRY + 1))
                    sleep $((2 ** FAIL_RETRY))
                fi
            done
        fi
        
        # Cleanup
        rm -rf "$WORKER_STATE_DIR"
        
        # Post completion notice with retry
        local DONE_MSG="✅ Agent \`${AGENT_ID}\` finished"
        local DONE_RETRY=0
        local DONE_SUCCESS=0
        while [[ $DONE_RETRY -lt $MAX_RETRIES ]] && [[ $DONE_SUCCESS -eq 0 ]]; do
            local DONE_RESPONSE
            DONE_RESPONSE=$(echo '{"content":"PLACEHOLDER"}' | jq --arg msg "$DONE_MSG" '.content = $msg' | \
                curl -s -w "\n%{http_code}" \
                -X POST \
                -H "Authorization: Bot ${BOT_TOKEN}" \
                -H "Content-Type: application/json" \
                -d @- \
                "https://discord.com/api/v10/channels/${WORKER_POOL_CHANNEL}/messages" 2>/dev/null)
            
            local DONE_HTTP=$(echo "$DONE_RESPONSE" | tail -1)
            if [[ "$DONE_HTTP" == "200" ]] || [[ "$DONE_HTTP" == "201" ]]; then
                DONE_SUCCESS=1
            else
                DONE_RETRY=$((DONE_RETRY + 1))
                sleep $((2 ** DONE_RETRY))
            fi
        done
    ) &
    
    echo "[$(date '+%H:%M:%S')] Agent ${AGENT_ID} spawned (PID: $!)"
}

# Main
echo "[$(date '+%H:%M:%S')] Dynamic Orchestrator starting..."

PENDING=$(get_pending_tasks)
[[ -z "$PENDING" ]] && echo "[$(date '+%H:%M:%S')] No pending tasks" && exit 0

echo "[$(date '+%H:%M:%S')] Found pending tasks..."

while IFS='|' read -r TASK_ID TASK_CONTENT; do
    [[ -z "$TASK_ID" ]] && continue
    
    is_assigned "$TASK_ID" && continue
    mark_assigned "$TASK_ID"
    
    PARSED=$(parse_task "$TASK_CONTENT")
    MODEL=$(echo "$PARSED" | cut -d'|' -f1)
    THINKING=$(echo "$PARSED" | cut -d'|' -f2)
    DESC=$(echo "$PARSED" | cut -d'|' -f3-)
    
    spawn_agent "$TASK_ID" "$MODEL" "$THINKING" "$DESC"
    sleep 2
    
done <<< "$PENDING"

echo "[$(date '+%H:%M:%S')] Orchestration complete."
