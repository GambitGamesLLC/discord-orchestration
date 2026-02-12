#!/bin/bash
#
# submit-to-queue.sh - Submit task to Discord #task-queue with proper formatting

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${REPO_DIR}/discord-config.env" ]]; then
    source "${REPO_DIR}/discord-config.env"
fi

TASK="${1:-}"
MODEL="${2:-}"
THINKING="${3:-}"

[[ -z "$TASK" ]] && {
    echo "Usage: $0 'task description' [model] [thinking]"
    echo ""
    echo "Examples:"
    echo "  $0 'Write a Python function to sort a list'"
    echo "  $0 'Review code' 'claude-sonnet-4' 'high'"
    exit 1
}

echo "Submitting to Discord #task-queue..."
echo "  Task: ${TASK:0:50}..."
[[ -n "$MODEL" ]] && echo "  Model: $MODEL"
[[ -n "$THINKING" ]] && echo "  Thinking: $THINKING"
echo ""

if [[ -n "${ORCHESTRATOR_AGENT_TOKEN:-}" && -n "${TASK_QUEUE_CHANNEL:-}" ]]; then
    # Submit task and get the message ID (which becomes the task ID)
    RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bot ${ORCHESTRATOR_AGENT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"content\":\"${TASK}\"}" \
        "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL}/messages" 2>/dev/null)
    
    TASK_ID=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
    
    if [[ -n "$TASK_ID" ]]; then
        # Edit the message to include the task ID at the top
        MSG_WITH_ID="**[Task: ${TASK_ID}]** ${TASK}"
        [[ -n "$MODEL" ]] && MSG_WITH_ID="${MSG_WITH_ID} [model:${MODEL}]"
        [[ -n "$THINKING" ]] && MSG_WITH_ID="${MSG_WITH_ID} [thinking:${THINKING}]"
        
        curl -s -X PATCH \
            -H "Authorization: Bot ${CHIP_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"content\":\"${MSG_WITH_ID}\"}" \
            "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL}/messages/${TASK_ID}" > /dev/null 2>&1
        
        echo "✅ Task posted to #task-queue (ID: ${TASK_ID})"
        echo "   Workers will pick it up via reaction claiming"
    else
        echo "❌ Failed: ${RESPONSE:0:100}"
        exit 1
    fi
else
    echo "❌ Discord not configured"
    exit 1
fi
