#!/bin/bash
#
# orchestrator-dynamic.sh - Dynamic agent spawning orchestrator
# Uses openclaw --local mode for embedded execution

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load config
if [[ -f "${REPO_DIR}/discord-config.env" ]]; then
    source "${REPO_DIR}/discord-config.env"
fi

BOT_TOKEN="${CHIP_TOKEN:-}"
TASK_QUEUE_CHANNEL="${TASK_QUEUE_CHANNEL:-}"
RESULTS_CHANNEL="${RESULTS_CHANNEL:-}"
WORKER_POOL_CHANNEL="${WORKER_POOL_CHANNEL:-}"

# Runtime tracking
RUNTIME_DIR="${REPO_DIR}/.runtime"
ASSIGNED_FILE="${RUNTIME_DIR}/assigned-tasks.txt"
mkdir -p "$RUNTIME_DIR"

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

# Get unassigned tasks from queue
get_pending_tasks() {
    local MESSAGES
    MESSAGES=$(discord_api GET "/channels/${TASK_QUEUE_CHANNEL}/messages?limit=20")
    
    [[ -z "$MESSAGES" ]] && return 0
    
    # Find messages without ✅ reaction
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
    
    # Add ✅ reaction to mark as claimed
    discord_api PUT "/channels/${TASK_QUEUE_CHANNEL}/messages/${TASK_ID}/reactions/%E2%9C%85/@me" > /dev/null 2>&1 || true
}

# Check if already assigned
is_assigned() {
    local TASK_ID="$1"
    
    # Check local file
    if [[ -f "$ASSIGNED_FILE" ]] && grep -q "^${TASK_ID}$" "$ASSIGNED_FILE" 2>/dev/null; then
        return 0
    fi
    
    # Check Discord reactions
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
    
    # Clean up task description
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
    
    echo "[$(date '+%H:%M:%S')] Spawning agent for task ${TASK_ID:0:12}..."
    
    # Post assignment notice
    local ASSIGN_MSG="🤖 **AGENT SPAWNED**\\nTask: ${TASK_DESC:0:60}...\\nAgent: \`${AGENT_ID}\`\\nModel: ${MODEL} | Thinking: ${THINKING}"
    discord_api POST "/channels/${WORKER_POOL_CHANNEL}/messages" "{\"content\":\"${ASSIGN_MSG}\"}" > /dev/null 2>&1 || true
    
    # Map model alias to full name for OpenRouter
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
    
    # Spawn agent in background using openclaw --local
    (
        echo "[$(date '+%H:%M:%S')] Agent ${AGENT_ID} starting..."
        
        # Run openclaw agent in local mode
        # Capture output to file first
        local OUTPUT_FILE="/tmp/${AGENT_ID}.txt"
        
        export OPENCLAW_MODEL="$MODEL_FLAG"
        
        # Use openclaw agent --local with proper message
        timeout 120 openclaw agent \
            --local \
            --session-id "${AGENT_ID}" \
            --message "${TASK_DESC}" \
            --thinking "${THINKING}" \
            > "$OUTPUT_FILE" 2>&1 || true
        
        # Extract result from output (last part after agent completes)
        local RESULT
        RESULT=$(tail -50 "$OUTPUT_FILE" 2>/dev/null | grep -v "^🦞" | tail -30)
        
        if [[ -n "$RESULT" && ${#RESULT} -gt 10 ]]; then
            # Success - post to Discord
            local RESULT_MSG="✅ **SUCCESS** \`${TASK_ID}\` by **${AGENT_ID}**\\n\\n**Result:**\\n\`\`\`${RESULT:0:1500}\`\`\`"
            discord_api POST "/channels/${RESULTS_CHANNEL}/messages" "{\"content\":\"${RESULT_MSG}\"}" > /dev/null 2>&1 || true
            echo "[$(date '+%H:%M:%S')] Agent ${AGENT_ID} completed successfully"
        else
            # Failed - post failure
            discord_api POST "/channels/${RESULTS_CHANNEL}/messages" "{\"content\":\"❌ **FAILED** \`${TASK_ID}\` - Agent produced no result\"}" > /dev/null 2>&1 || true
            echo "[$(date '+%H:%M:%S')] Agent ${AGENT_ID} failed"
        fi
        
        # Cleanup
        rm -f "$OUTPUT_FILE"
        
        # Post completion notice
        discord_api POST "/channels/${WORKER_POOL_CHANNEL}/messages" "{\"content\":\"✅ Agent \`${AGENT_ID}\` finished\"}" > /dev/null 2>&1 || true
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
    
    is_assigned "$TASK_ID" && echo "[$(date '+%H:%M:%S')] ${TASK_ID:0:12} already assigned" && continue
    
    mark_assigned "$TASK_ID"
    
    PARSED=$(parse_task "$TASK_CONTENT")
    MODEL=$(echo "$PARSED" | cut -d'|' -f1)
    THINKING=$(echo "$PARSED" | cut -d'|' -f2)
    DESC=$(echo "$PARSED" | cut -d'|' -f3-)
    
    spawn_agent "$TASK_ID" "$MODEL" "$THINKING" "$DESC"
    sleep 2
    
done <<< "$PENDING"

echo "[$(date '+%H:%M:%S')] Orchestration complete. Agents running in background."
