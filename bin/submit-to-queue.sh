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

# Build message with optional tags
MSG="${TASK}"
[[ -n "$MODEL" ]] && MSG="${MSG} [model:${MODEL}]"
[[ -n "$THINKING" ]] && MSG="${MSG} [thinking:${THINKING}]"

echo "Submitting to Discord #task-queue..."
echo "  Task: ${TASK:0:50}..."

if [[ -n "${CHIP_TOKEN:-}" && -n "${TASK_QUEUE_CHANNEL:-}" ]]; then
    RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bot ${CHIP_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"content\":\"${MSG}\"}" \
        "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL}/messages" 2>/dev/null)
    
    if echo "$RESPONSE" | grep -q '"id"'; then
        echo "✅ Task posted to #task-queue"
        echo "   Workers will pick it up via reaction claiming"
    else
        echo "❌ Failed: ${RESPONSE:0:100}"
        exit 1
    fi
else
    echo "❌ Discord not configured"
    exit 1
fi
