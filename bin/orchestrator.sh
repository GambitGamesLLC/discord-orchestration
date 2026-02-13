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

# Worker retention policy (hours)
# Successful workers are auto-deleted after this time
# Failed workers are preserved for manual investigation
WORKER_RETENTION_HOURS="${WORKER_RETENTION_HOURS:-24}"

# Runtime tracking
RUNTIME_DIR="${REPO_DIR}/.runtime"
ASSIGNED_FILE="${RUNTIME_DIR}/assigned-tasks.txt"
mkdir -p "$RUNTIME_DIR"

WORKERS_DIR="${REPO_DIR}/workers"
mkdir -p "$WORKERS_DIR"

# Health check reporting function
report_health() {
    local STATUS="${1:-unknown}"
    local MESSAGE="${2:-}"
    
    echo "[$(date '+%H:%M:%S')] ORCHESTRATOR_HEALTH: status=${STATUS} ${MESSAGE}"
    
    # Log to systemd journal if available
    if command -v systemd-cat &>/dev/null; then
        echo "Discord Orchestrator: status=${STATUS} ${MESSAGE}" | systemd-cat -t discord-orchestrator -p info
    fi
}

# Self-check: verify this orchestrator instance is properly configured
check_orchestrator_health() {
    local ISSUES=()
    
    # Check config loaded
    if [[ -z "$BOT_TOKEN" ]]; then
        ISSUES+=("BOT_TOKEN not set - check discord-config.env")
    fi
    
    if [[ -z "$TASK_QUEUE_CHANNEL" ]]; then
        ISSUES+=("TASK_QUEUE_CHANNEL not set")
    fi
    
    if [[ -z "$RESULTS_CHANNEL" ]]; then
        ISSUES+=("RESULTS_CHANNEL not set")
    fi
    
    # Check Gateway is reachable
    if ! curl -s http://127.0.0.1:18789/health &>/dev/null; then
        ISSUES+=("OpenClaw Gateway not reachable at :18789")
    fi
    
    # Report status
    if [[ ${#ISSUES[@]} -eq 0 ]]; then
        report_health "healthy" "All systems operational"
        return 0
    else
        report_health "unhealthy" "Issues: ${ISSUES[*]}"
        return 1
    fi
}

# Run health check at startup
check_orchestrator_health || true

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

# Check if already assigned (Discord reaction is atomic - no local file cache)
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
    
    # Parse worker type tag [worker:godot-tester]
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
    
    # Support custom AGENTS.md template via environment variable
    if [[ -n "${AGENTS_MD_TEMPLATE:-}" && -f "${AGENTS_MD_TEMPLATE}" ]]; then
        # Use custom template and append task info
        cp "${AGENTS_MD_TEMPLATE}" "${WORKER_STATE_DIR}/AGENTS.md"
        cat >> "${WORKER_STATE_DIR}/AGENTS.md" << EOF

---

## Current Task Context
**Task ID:** ${TASK_ID}
**Agent ID:** ${AGENT_ID}
**Task Directory:** ${TASK_DIR}

## Task Description
${TASK_DESC}
EOF
        echo "[$(date '+%H:%M:%S')] Using custom AGENTS.md: ${AGENTS_MD_TEMPLATE}" >&2
    else
        # Default AGENTS.md
        cat > "${WORKER_STATE_DIR}/AGENTS.md" << EOF
# ${AGENT_ID}

## Task
${TASK_DESC}

## ⚠️ CRITICAL: English Only
**ALL output must be in English.**
- Respond in English only
- If researching non-English sources, translate findings to English
- System locale: en_US.UTF-8

This ensures consistent communication with the orchestrator and user.

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
    
    # Copy TOOLS.md if it exists (like old workers)
    if [[ -f "${WORKERS_DIR}/TOOLS.md" ]]; then
        cp "${WORKERS_DIR}/TOOLS.md" "${WORKER_STATE_DIR}/TOOLS.md"
    fi
    
    # Copy AGENTS.md to task dir so agent finds it (agent runs from TASK_DIR)
    cp "${WORKER_STATE_DIR}/AGENTS.md" "${TASK_DIR}/AGENTS.md"
    
    # Write TASK.txt (like old workers)
    cat > "${TASK_DIR}/TASK.txt" << EOF
TASK: ${TASK_DESC}
EOF
    
    # Post notice (outside subshell so discord_api works)
    local WORKER_INFO=""
    [[ -n "$WORKER_TYPE" ]] && WORKER_INFO="\\nWorker: \`${WORKER_TYPE}\`"
    discord_api POST "/channels/${WORKER_POOL_CHANNEL}/messages" \
        "{\"content\":\"🤖 **AGENT SPAWNED**\\nTask: ${TASK_DESC:0:60}...\\nAgent: \`${AGENT_ID}\`${WORKER_INFO}\"}" > /dev/null 2>&1 || true
    
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
        export SUMMARY_MAX_LENGTH="${SUMMARY_MAX_LENGTH:-2000}"  # Summary truncation limit
        
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
        
        # Support extra PYTHONPATH for custom modules (e.g., godot_bridge)
        if [[ -n "${EXTRA_PYTHONPATH:-}" ]]; then
            export PYTHONPATH="${EXTRA_PYTHONPATH}${PYTHONPATH:+:$PYTHONPATH}"
            echo "[$(date '+%H:%M:%S')] PYTHONPATH extended: ${PYTHONPATH}" >> agent-output.log
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
        
        # OPENCLAW_STATE_DIR changes where session files are stored
        local STATE_DIR="${OPENCLAW_STATE_DIR:-${HOME}/.openclaw}"
        local SESSION_FILE="${STATE_DIR}/agents/main/sessions/${AGENT_ID}-${TASK_ID}.jsonl"
        
        # Wait for session file to be written (retry up to 10 times, 500ms delay)
        local SESSION_RETRY=0
        while [[ ! -f "$SESSION_FILE" ]] && [[ $SESSION_RETRY -lt 10 ]]; do
            sleep 0.5
            SESSION_RETRY=$((SESSION_RETRY + 1))
        done
        
        if [[ -f "$SESSION_FILE" ]]; then
            # Additional wait for file to be fully written
            sleep 0.5
            
            local TOKENS_JSON
            TOKENS_JSON=$(tail -50 "$SESSION_FILE" 2>/dev/null | python3 -c "
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
                    # Pricing is in main config, not isolated worker config
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
        else
            echo "[$(date '+%H:%M:%S')] WARNING: Session file not found: $SESSION_FILE" >> agent-output.log
        fi
        
        # Note: Using 4-backtick fences (````) so inner ``` renders correctly
        
        # FALLBACK: Generate SUMMARY.txt only if worker didn't create it
        # Workers SHOULD write their own SUMMARY.txt per AGENTS.md instructions
        # This fallback exists for backward compatibility
        if [[ -f "RESULT.txt" ]] && [[ -s "RESULT.txt" ]] && [[ ! -f "SUMMARY.txt" ]]; then
            echo "[$(date '+%H:%M:%S')] WARNING: Worker did not create SUMMARY.txt, generating fallback" >> agent-output.log
            local RESULT_CONTENT=$(cat RESULT.txt 2>/dev/null)
            local TRUNCATION_SUFFIX="... (truncated, see RESULT.txt)"
            local SUFFIX_LENGTH=${#TRUNCATION_SUFFIX}
            local EFFECTIVE_LIMIT=$((SUMMARY_MAX_LENGTH - SUFFIX_LENGTH))
            
            if [[ ${#RESULT_CONTENT} -gt $EFFECTIVE_LIMIT ]]; then
                local SUMMARY="${RESULT_CONTENT:0:$EFFECTIVE_LIMIT}${TRUNCATION_SUFFIX}"
            else
                local SUMMARY="$RESULT_CONTENT"
            fi
            echo "$SUMMARY" > SUMMARY.txt
        fi
        
        # Check for result and post to Discord
        # Common retry settings for both success and failure
        local MAX_RETRIES=5
        
        if [[ -f "RESULT.txt" ]]; then
            local RESULT=$(cat RESULT.txt 2>/dev/null)
            # Use SUMMARY.txt content if available, fall back to RESULT.txt
            local POST_CONTENT
            if [[ -f "SUMMARY.txt" ]]; then
                POST_CONTENT=$(cat SUMMARY.txt 2>/dev/null)
            else
                POST_CONTENT="$RESULT"
            fi
            
            # Build nicely formatted Discord message (like old system)
            local DISPLAY_COST="${COST:-N/A}"
            
            # List files with proper spacing (comma + space between each)
            # Always ensure RESULT.txt and SUMMARY.txt are included
            local ALL_FILES=$(ls -1 "$TASK_DIR" 2>/dev/null)
            if ! echo "$ALL_FILES" | grep -q "^RESULT\.txt$"; then
                ALL_FILES="RESULT.txt (expected)
$ALL_FILES"
            fi
            if ! echo "$ALL_FILES" | grep -q "^SUMMARY\.txt$"; then
                ALL_FILES="SUMMARY.txt
$ALL_FILES"
            fi
            local FILES=$(echo "$ALL_FILES" | tr '\n' ',' | sed 's/,$//; s/,/, /g')
            
            # Build message - single code block for easy copy/paste
            local MSG=$(printf '```\n[SUCCESS] %s by %s\nModel: %s | Thinking: %s | Tokens: %s in / %s out | Cost: $%s\n\nTask Prompt:\n%s\n\nSummary:\n%s\n\nFiles: %s\nWorkspace: %s\n```' \
                "$TASK_ID" "$AGENT_ID" "$MODEL_FLAG" "$THINKING" "$TOKENS_IN" "$TOKENS_OUT" "$DISPLAY_COST" \
                "${TASK_DESC:0:500}" "${POST_CONTENT:0:800}" "$FILES" "$TASK_DIR")
            
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
            local FAIL_MSG=$(printf '```\n[FAILED] %s by %s\nModel: %s | Thinking: %s\n\nTask:\n%s\n\n❌ No result produced\n```' \
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
        
        # Retention Policy: Success = schedule deletion, Fail = preserve for debugging
        if [[ -f "RESULT.txt" ]]; then
            # SUCCESS: Schedule auto-deletion after retention period
            local RETENTION_HOURS="${WORKER_RETENTION_HOURS:-24}"
            local DELETE_TIME=$(date -d "+${RETENTION_HOURS} hours" "+%H:%M %Y-%m-%d" 2>/dev/null || date -v+${RETENTION_HOURS}H "+%H:%M %Y-%m-%d" 2>/dev/null || echo "+${RETENTION_HOURS} hours")
            
            # Use 'at' for one-time scheduled deletion (gracefully handles already-deleted files)
            if command -v at &> /dev/null; then
                echo "rm -rf '$WORKER_STATE_DIR' 2>/dev/null || true" | at "$DELETE_TIME" 2>/dev/null || true
                echo "[$(date '+%H:%M:%S')] Scheduled deletion at $DELETE_TIME (${RETENTION_HOURS}h retention)" >> agent-output.log
            else
                # Fallback: nohup + sleep in background (handles missing files gracefully)
                (sleep $((RETENTION_HOURS * 3600)) && rm -rf "$WORKER_STATE_DIR" 2>/dev/null) &
                echo "[$(date '+%H:%M:%S')] Scheduled deletion in ${RETENTION_HOURS}h (background process)" >> agent-output.log
            fi
        else
            # FAILURE: Preserve workspace for manual investigation
            echo "[$(date '+%H:%M:%S')] PRESERVED: No RESULT.txt - workspace kept for debugging: $WORKER_STATE_DIR" >> agent-output.log
        fi
        
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

# Array to track agent PIDs and their timeouts
AGENT_PIDS=""
AGENT_TIMEOUTS=""

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
    
    # Track the PID for waiting later (no 'local' in main body)
    AGENT_PID=$!
    AGENT_PIDS="$AGENT_PIDS $AGENT_PID"
    
    # Calculate timeout for this agent (default 120s + 5s buffer)
    AGENT_WAIT_TIME=125  # 120s default + 5s buffer
    if [[ "${THINKING}" == "high" ]]; then
        AGENT_WAIT_TIME=305  # 300s for high thinking + 5s buffer
    fi
    if [[ -n "${TIMEOUT:-}" ]]; then
        AGENT_WAIT_TIME=$((TIMEOUT + 5))
    fi
    AGENT_TIMEOUTS="$AGENT_TIMEOUTS $AGENT_WAIT_TIME"
    
    sleep 2
    
done <<< "$PENDING"

echo "[$(date '+%H:%M:%S')] Orchestration complete. Waiting for agents to finish..."

# Wait for all agents to complete (with individual timeouts)
for PID in $AGENT_PIDS; do
    # Extract corresponding timeout (simple approach - use max timeout)
    wait $PID || true
done

echo "[$(date '+%H:%M:%S')] All agents finished."

# Final health report
COMPLETED_COUNT=$(echo "$AGENT_PIDS" | wc -w)
report_health "complete" "Processed ${COMPLETED_COUNT} tasks, all agents finished"
