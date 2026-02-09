#!/bin/bash
#
# orchestrator-discord.sh - Chip orchestrates workers via Discord
#
# Usage: ./orchestrator-discord.sh --task "description" [--model model] [--thinking level]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config if exists
if [[ -f "${SCRIPT_DIR}/discord-config.env" ]]; then
    source "${SCRIPT_DIR}/discord-config.env"
fi

# Parse arguments
TASK=""
MODEL="openrouter/moonshotai/kimi-k2.5"
THINKING="medium"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task) TASK="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --thinking) THINKING="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "$TASK" ]] && { echo "Usage: $0 --task 'description' [--model model] [--thinking level]"; exit 1; }

# Generate task ID
TASK_ID="task-$(date +%s)-${RANDOM}"

echo "======================================"
echo "Discord Orchestrator"
echo "======================================"
echo ""
echo "Task ID: ${TASK_ID}"
echo "Task: ${TASK:0:60}..."
echo "Model: ${MODEL}"
echo "Thinking: ${THINKING}"
echo ""

# Post task to Discord task queue
post_task_to_discord() {
    local MSG="**[NEW TASK]** \`${TASK_ID}\`
**Description:** ${TASK}
**Model:** ${MODEL}
**Thinking:** ${THINKING}

*Waiting for worker...*"
    
    if command -v openclaw &> /dev/null; then
        openclaw message send \
            --channel discord \
            --to "${TASK_QUEUE_CHANNEL:-task-queue}" \
            --message "$MSG" \
            2>/dev/null || true
    fi
    
    # Also add to local queue for hybrid mode
    mkdir -p /tmp/discord-tasks
    echo "${TASK_ID}|${TASK}|${MODEL}|${THINKING}" >> /tmp/discord-tasks/queue.txt
    
    echo "✓ Task posted to queue"
}

# Monitor for result
monitor_for_result() {
    echo ""
    echo "Monitoring for result (120s timeout)..."
    echo ""
    
    local TIMEOUT=120
    local ELAPSED=0
    
    while [[ $ELAPSED -lt $TIMEOUT ]]; do
        # Check local results file
        if [[ -f /tmp/discord-tasks/results.txt ]]; then
            local RESULT_LINE
            RESULT_LINE=$(grep "^${TASK_ID}" /tmp/discord-tasks/results.txt 2>/dev/null || echo "")
            
            if [[ -n "$RESULT_LINE" ]]; then
                echo "✓ Result received!"
                echo ""
                
                # Parse result
                local WORKER_ID STATUS TIMESTAMP RESULT
                WORKER_ID=$(echo "$RESULT_LINE" | cut -d'|' -f2)
                STATUS=$(echo "$RESULT_LINE" | cut -d'|' -f3)
                TIMESTAMP=$(echo "$RESULT_LINE" | cut -d'|' -f4)
                RESULT=$(echo "$RESULT_LINE" | cut -d'|' -f5-)
                
                echo "======================================"
                echo "Task Complete: ${TASK_ID}"
                echo "======================================"
                echo "Status: ${STATUS}"
                echo "Worker: ${WORKER_ID}"
                echo ""
                echo "Result:"
                echo "${RESULT}"
                echo ""
                
                return 0
            fi
        fi
        
        printf "\r  %2ds elapsed... " $ELAPSED
        sleep 2
        ELAPSED=$((ELAPSED + 2))
    done
    
    echo ""
    echo "⚠ Timeout waiting for result"
    return 1
}

# Main
post_task_to_discord
monitor_for_result
