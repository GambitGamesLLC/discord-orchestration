#!/bin/bash
#
# orchestrator-assign.sh - Centralized task assignment to prevent race conditions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load config
if [[ -f "${REPO_DIR}/discord-config.env" ]]; then
    source "${REPO_DIR}/discord-config.env"
fi

BOT_TOKEN="${CHIP_TOKEN:-}"
TASK_QUEUE_CHANNEL="${TASK_QUEUE_CHANNEL:-}"
WORKER_POOL_CHANNEL="${WORKER_POOL_CHANNEL:-}"

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

# Get list of READY workers
get_ready_workers() {
    local MESSAGES
    MESSAGES=$(discord_api GET "/channels/${WORKER_POOL_CHANNEL}/messages?limit=20")
    
    # Extract worker names from recent READY messages
    echo "$MESSAGES" | python3 -c "
import json, sys, re
data = json.load(sys.stdin)
workers = set()
for msg in data:
    content = msg.get('content', '')
    # Look for [READY] Worker-X pattern
    match = re.search(r'READY.*?(worker-\d+)', content, re.IGNORECASE)
    if match:
        workers.add(match.group(1))
for w in sorted(workers):
    print(w)
" 2>/dev/null
}

# Assign task to specific worker
assign_task() {
    local TASK_MSG_ID="$1"
    local WORKER_NAME="$2"
    local TASK_DESC="$3"
    local MODEL="$4"
    local THINKING="$5"
    
    echo "[$(date '+%H:%M:%S')] Assigning task ${TASK_MSG_ID:0:12}... to ${WORKER_NAME}"
    
    # Add assignment reaction to task
    discord_api PUT "/channels/${TASK_QUEUE_CHANNEL}/messages/${TASK_MSG_ID}/reactions/%E2%9C%85/@me" > /dev/null 2>&1 || true
    
    # Post assignment notification in worker pool
    local MSG="🎯 **TASK ASSIGNED**\nTask: ${TASK_DESC:0:60}...\nAssigned to: **${WORKER_NAME}**\nModel: ${MODEL} | Thinking: ${THINKING}\n[Claim: https://discord.com/channels/${GUILD_ID:-}/${TASK_QUEUE_CHANNEL}/${TASK_MSG_ID}]"
    
    discord_api POST "/channels/${WORKER_POOL_CHANNEL}/messages" "{\"content\":\"${MSG}\"}" > /dev/null 2>&1 || true
    
    echo "[$(date '+%H:%M:%S')] Assignment posted"
}

# Main orchestration loop
echo "[$(date '+%H:%M:%S')] Orchestrator starting..."

# Check for unassigned tasks in queue
MESSAGES=$(discord_api GET "/channels/${TASK_QUEUE_CHANNEL}/messages?limit=10")

# Find tasks without ✅ reaction
UNASSIGNED=$(echo "$MESSAGES" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for msg in data:
    reacts = msg.get('reactions', [])
    has_check = any(r.get('emoji', {}).get('name') == '✅' for r in reacts)
    if not has_check:
        print(f\"{msg['id']}|{msg['content'][:200]}\")
" 2>/dev/null)

if [[ -z "$UNASSIGNED" ]]; then
    echo "[$(date '+%H:%M:%S')] No unassigned tasks found"
    exit 0
fi

# Get available workers
WORKERS=$(get_ready_workers)
if [[ -z "$WORKERS" ]]; then
    echo "[$(date '+%H:%M:%S')] No READY workers found, skipping assignment"
    exit 0
fi

# Assign tasks round-robin
WORKER_ARRAY=($WORKERS)
WORKER_COUNT=${#WORKER_ARRAY[@]}
WORKER_INDEX=0

while IFS='|' read -r MSG_ID CONTENT; do
    [[ -z "$MSG_ID" ]] && continue
    
    # Extract task details
    TASK_DESC="$CONTENT"
    MODEL="cheap"
    THINKING="medium"
    
    # Parse model [model:xxx]
    if [[ "$CONTENT" =~ \[model:([^\]]+)\] ]]; then
        MODEL="${BASH_REMATCH[1]}"
    fi
    
    # Parse thinking [thinking:xxx]
    if [[ "$CONTENT" =~ \[thinking:([^\]]+)\] ]]; then
        THINKING="${BASH_REMATCH[1]}"
    fi
    
    # Get next worker (round-robin)
    WORKER="${WORKER_ARRAY[$WORKER_INDEX]}"
    WORKER_INDEX=$(((WORKER_INDEX + 1) % WORKER_COUNT))
    
    assign_task "$MSG_ID" "$WORKER" "$TASK_DESC" "$MODEL" "$THINKING"
    
done <<< "$UNASSIGNED"

echo "[$(date '+%H:%M:%S')] Orchestration complete"
