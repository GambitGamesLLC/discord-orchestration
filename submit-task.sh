#!/bin/bash
#
# submit-task.sh - Submit a task to the worker queue
#
# Usage: ./submit-task.sh "Your task description" [model] [thinking]

set -euo pipefail

TASK="${1:-}"
MODEL="${2:-openrouter/moonshotai/kimi-k2.5}"
THINKING="${3:-medium}"

[[ -z "$TASK" ]] && { 
    echo "Usage: $0 'task description' [model] [thinking]"
    echo ""
    echo "Examples:"
    echo "  $0 'Write a Python function to sort a list'"
    echo "  $0 'Review this code' 'anthropic/claude-sonnet-4' 'high'"
    exit 1
}

TASK_ID="task-$(date +%s)-${RANDOM}"

mkdir -p /tmp/discord-tasks

echo "${TASK_ID}|${TASK}|${MODEL}|${THINKING}" >> /tmp/discord-tasks/queue.txt

echo "✓ Task submitted: ${TASK_ID}"
echo "  Description: ${TASK:0:60}..."
echo "  Model: ${MODEL}"
echo "  Thinking: ${THINKING}"
echo ""
echo "  Queue position: $(wc -l < /tmp/discord-tasks/queue.txt)"
