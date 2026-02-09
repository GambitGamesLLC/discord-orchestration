#!/bin/bash
#
# submit-to-discord.sh - Submit a task to Discord #task-queue
#
# Usage: ./submit-to-discord.sh "Your task description" [--model model] [--thinking level]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load config
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
    echo "  $0 'Review this code' 'claude-sonnet-4' 'high'"
    echo ""
    echo "Or add model/thinking inline:"
    echo "  $0 'Review code [model:claude-sonnet-4] [thinking:high]'"
    exit 1
}

# Build optional tags
TAGS=""
[[ -n "$MODEL" ]] && TAGS=" [model:${MODEL}]"
[[ -n "$THINKING" ]] && TAGS="${TAGS} [thinking:${THINKING}]"

# Full message
MESSAGE="${TASK}${TAGS}"

echo "Submitting task to Discord #task-queue..."
echo "  Task: ${TASK:0:50}..."
[[ -n "$MODEL" ]] && echo "  Model: $MODEL"
[[ -n "$THINKING" ]] && echo "  Thinking: $THINKING"
echo ""

# Post to Discord using Chip's token
if [[ -n "${CHIP_TOKEN:-}" && -n "${TASK_QUEUE_CHANNEL:-}" ]]; then
    RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bot ${CHIP_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"content\":\"${MESSAGE}\"}" \
        "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL}/messages" 2>/dev/null || echo "")
    
    if echo "$RESPONSE" | grep -q '"id"'; then
        echo "✅ Task posted to Discord #task-queue!"
        echo "   Workers will pick it up shortly."
    else
        echo "❌ Failed to post to Discord"
        echo "   Error: ${RESPONSE:0:100}"
        echo ""
        echo "Falling back to file queue..."
        # Add to file as fallback
        mkdir -p /tmp/discord-tasks
        task_id="task-$(date +%s)-${RANDOM}"
        echo "${task_id}|${TASK}|${MODEL:-openrouter/moonshotai/kimi-k2.5}|${THINKING:-medium}" >> /tmp/discord-tasks/queue.txt
        echo "✅ Task added to file queue instead"
    fi
else
    echo "⚠️  Discord not configured, using file queue..."
    mkdir -p /tmp/discord-tasks
    task_id="task-$(date +%s)-${RANDOM}"
    echo "${task_id}|${TASK}|${MODEL:-openrouter/moonshotai/kimi-k2.5}|${THINKING:-medium}" >> /tmp/discord-tasks/queue.txt
    echo "✅ Task added to file queue"
fi

echo ""
echo "Monitor #worker-pool and #results for progress"
