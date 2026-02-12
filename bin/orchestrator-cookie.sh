#!/bin/bash
#
# orchestrator-cookie.sh - Modified orchestrator with dynamic AGENTS.md support
# 
# Usage with custom AGENTS.md:
#   AGENTS_MD_TEMPLATE=/path/to/godot-tester.md ./bin/orchestrator-cookie.sh
#
# Usage with extra PYTHONPATH (e.g., for godot_bridge):
#   EXTRA_PYTHONPATH=/home/derrick/Documents/GitHub/openclaw-godot/src ./bin/orchestrator-cookie.sh
#
# Combined:
#   AGENTS_MD_TEMPLATE=/path/to/godot-tester.md \
#   EXTRA_PYTHONPATH=/home/derrick/Documents/GitHub/openclaw-godot/src \
#   ./bin/orchestrator-cookie.sh

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

# Support custom config path
DISCORD_CONFIG="${DISCORD_CONFIG:-${REPO_DIR}/discord-config.env}"
if [[ -f "$DISCORD_CONFIG" ]]; then
    source "$DISCORD_CONFIG"
fi

# Dynamic AGENTS.md support
AGENTS_MD_TEMPLATE="${AGENTS_MD_TEMPLATE:-}"
EXTRA_PYTHONPATH="${EXTRA_PYTHONPATH:-}"

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

# Log dynamic configuration
echo "[$(date '+%H:%M:%S')] Orchestrator starting..."
[[ -n "$AGENTS_MD_TEMPLATE" ]] && echo "[$(date '+%H:%M:%S')] Using custom AGENTS.md: $AGENTS_MD_TEMPLATE"
[[ -n "$EXTRA_PYTHONPATH" ]] && echo "[$(date '+%H:%M:%S')] Extra PYTHONPATH: $EXTRA_PYTHONPATH"

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
    local LOCK_FILE="${ASSIGNED_FILE}.lock"
    flock "$LOCK_FILE" -c "echo \"$TASK_ID\" >> \"$ASSIGNED_FILE\""
    discord_api PUT "/channels/${TASK_QUEUE_CHANNEL}/messages/${TASK_ID}/reactions/%E2%9C%85/@me" > /dev/null 2>&1 || true
}

# Check if already assigned
is_assigned() {
    local TASK_ID="$1"
    
    local REACTIONS
    REACTIONS=$(discord_api GET "/channels/${TASK_QUEUE_CHANNEL}/messages/${TASK_ID}/reactions/%E2%9C%85")
    local COUNT
    COUNT=$(echo "$REACTIONS" | python3 -c "import json,sys; data=json.load(sys.stdin); print(len(data) if isinstance(data, list) else 0)" 2>/dev/null)
    
    if [[ "${COUNT:-0}" -gt 0 ]]; then
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
    
    # NEW: Parse worker type from task
    local WORKER_TYPE=""
    if [[ "$CONTENT" =~ \[worker:([^\]]+)\] ]]; then
        WORKER_TYPE="${BASH_REMATCH[1]}"
    fi
    
    local DESC="$CONTENT"
    DESC=$(echo "$DESC" | sed 's/\[model:[^]]*\]//g; s/\[thinking:[^]]*\]//g; s/\[worker:[^]]*\]//g; s/\*\*//g')
    DESC=$(echo "$DESC" | sed 's/^ *//;s/ *$//')
    
    echo "$MODEL|$THINKING|$DESC|$WORKER_TYPE"
}

# Spawn agent to execute task
spawn_agent() {
    local TASK_ID="$1"
    local MODEL="$2"
    local THINKING="$3"
    local TASK_DESC="$4"
    local WORKER_TYPE="${5:-}"
    
    local AGENT_ID="agent-$(date +%s)-${RANDOM}"
    local WORKER_STATE_DIR="${WORKERS_DIR}/${AGENT_ID}"
    local TASK_DIR="${WORKER_STATE_DIR}/tasks/${TASK_ID}"
    
    echo "[$(date '+%H:%M:%S')] Spawning agent for task ${TASK_ID:0:12}..."
    [[ -n "$WORKER_TYPE" ]] && echo "[$(date '+%H:%M:%S')] Worker type: $WORKER_TYPE"
    
    # Create workspace
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
    
    # DYNAMIC AGENTS.md: Use custom template if provided
    if [[ -n "$AGENTS_MD_TEMPLATE" && -f "$AGENTS_MD_TEMPLATE" ]]; then
        # Use custom template
        cp "$AGENTS_MD_TEMPLATE" "${WORKER_STATE_DIR}/AGENTS.md"
        
        # Append task-specific info
        cat >> "${WORKER_STATE_DIR}/AGENTS.md" << EOF

---

## Current Task
${TASK_DESC}

## Task Directory
${TASK_DIR}

## Agent ID
${AGENT_ID}

## Worker Type
${WORKER_TYPE:-default}
EOF
        
        echo "[$(date '+%H:%M:%S')] Using custom AGENTS.md template"
    else
        # Default AGENTS.md
        cat > "${WORKER_STATE_DIR}/AGENTS.md" << EOF
# ${AGENT_ID}

## Task
${TASK_DESC}

## Model Defaults
- Primary: openrouter/moonshotai/kimi-k2.5
- Cheap: openrouter/stepfun/step-3.5-flash:free
- Coder: openrouter/qwen/qwen3-coder-next
- Research: openrouter/google/gemini-3-pro-preview

## Output Files (REQUIRED)

You MUST write TWO files:

1. **RESULT.txt** - Complete detailed result (full output)
2. **SUMMARY.txt** - Condensed summary (~2000 chars max)

### SUMMARY.txt Guidelines:
- Maximum ${SUMMARY_MAX_LENGTH:-2000} characters
- Include key findings and conclusions
- Can truncate with "... (see RESULT.txt)" if needed
- Used for Discord display (saves tokens)
- Write AFTER RESULT.txt is complete

### Why Two Files?
- RESULT.txt = Full context for future reference
- SUMMARY.txt = Quick review without loading full context
- Discord shows SUMMARY.txt (reduces token usage)
EOF
    fi
    
    # Copy TOOLS.md if it exists
    if [[ -f "${WORKERS_DIR}/TOOLS.md" ]]; then
        cp "${WORKERS_DIR}/TOOLS.md" "${WORKER_STATE_DIR}/TOOLS.md"
    fi
    
    # Write TASK.txt
    cat > "${TASK_DIR}/TASK.txt" << EOF
TASK: ${TASK_DESC}
EOF
    
    # Post notice
    discord_api POST "/channels/${WORKER_POOL_CHANNEL}/messages" \
        "{\"content\":\"🤖 **AGENT SPAWNED**\\nTask: ${TASK_DESC:0:60}...\\nAgent: \`${AGENT_ID}\`\\nWorker: ${WORKER_TYPE:-default}\"}" > /dev/null 2>&1 || true
    
    # Spawn agent in background
    (
        # Export all needed variables
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
        export TIMEOUT="${TIMEOUT:-}"
        export SUMMARY_MAX_LENGTH="${SUMMARY_MAX_LENGTH:-2000}"
        
        cd "$TASK_DIR"
        
        # Set timeout
        local AGENT_TIMEOUT="${TIMEOUT:-}"
        if [[ -z "$AGENT_TIMEOUT" ]]; then
            if [[ "${THINKING}" == "high" ]]; then
                AGENT_TIMEOUT=300
            else
                AGENT_TIMEOUT=120
            fi
        fi
        
        # Build PythonPATH with extra paths
        local PYTHON_PATH="${EXTRA_PYTHONPATH}"
        if [[ -n "$PYTHON_PATH" ]]; then
            PYTHON_PATH="${PYTHON_PATH}:${PYTHONPATH:-}"
        else
            PYTHON_PATH="${PYTHONPATH:-}"
        fi
        
        # Run agent with optional extra PYTHONPATH
        if [[ -n "$PYTHON_PATH" ]]; then
            echo "[$(date '+%H:%M:%S')] Running with PYTHONPATH: $PYTHON_PATH" >> agent-output.log
            PYTHONPATH="$PYTHON_PATH" timeout $AGENT_TIMEOUT openclaw agent \
                --session-id "${AGENT_ID}-${TASK_ID}" \
                --message "Complete the task in TASK.txt. Write result to RESULT.txt in ${TASK_DIR}/" \
                --thinking "${THINKING}" \
                > agent-output.log 2>&1 || true
        else
            timeout $AGENT_TIMEOUT openclaw agent \
                --session-id "${AGENT_ID}-${TASK_ID}" \
                --message "Complete the task in TASK.txt. Write result to RESULT.txt in ${TASK_DIR}/" \
                --thinking "${THINKING}" \
                > agent-output.log 2>&1 || true
        fi
        
        # Result posting (same as original)... 
        # [Rest of result posting logic from original script]
        
        # Cleanup
        rm -rf "$WORKER_STATE_DIR"
        
    ) &
    
    echo "[$(date '+%H:%M:%S')] Agent ${AGENT_ID} spawned (PID: $!)"
}

# Main
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
    DESC=$(echo "$PARSED" | cut -d'|' -f3)
    WORKER=$(echo "$PARSED" | cut -d'|' -f4)
    
    spawn_agent "$TASK_ID" "$MODEL" "$THINKING" "$DESC" "$WORKER"
    sleep 2
    
done <<< "$PENDING"

echo "[$(date '+%H:%M:%S')] Orchestration complete."
