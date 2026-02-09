#!/bin/bash
#
# test-multi-discord.sh - Test multiple Discord workers

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config
if [[ -f "${SCRIPT_DIR}/discord-config.env" ]]; then
    source "${SCRIPT_DIR}/discord-config.env"
fi

echo "======================================"
echo "Multi-Worker Discord Test"
echo "======================================"
echo ""

# Cleanup
pkill -f "worker-discord-curl" 2>/dev/null || true
pkill -f "worker-manager-discord-curl" 2>/dev/null || true
rm -rf /tmp/discord-tasks /tmp/discord-workers
mkdir -p /tmp/discord-tasks
sleep 1

echo "✓ Cleaned up previous runs"
echo ""

# Start manager
echo "Starting manager with 3 workers..."
bash "${SCRIPT_DIR}/worker-manager-discord-curl.sh" --workers 3 > /tmp/manager.log 2>&1 &
MANAGER_PID=$!
sleep 5

echo "✓ Manager started (PID: $MANAGER_PID)"
echo ""

# Submit tasks
echo "Submitting 3 tasks..."
echo "task-multi-1|Write a Python function to calculate factorial|openrouter/moonshotai/kimi-k2.5|low" >> /tmp/discord-tasks/queue.txt
echo "task-multi-2|Write a JavaScript function to reverse a string|openrouter/moonshotai/kimi-k2.5|low" >> /tmp/discord-tasks/queue.txt
echo "task-multi-3|Write a bash script to list files|openrouter/moonshotai/kimi-k2.5|low" >> /tmp/discord-tasks/queue.txt
echo "✓ Tasks submitted"
echo ""

# Monitor
echo "Monitoring (90s timeout)..."
TIMEOUT=90
ELAPSED=0
COMPLETED=0

while [[ $ELAPSED -lt $TIMEOUT ]] && [[ $COMPLETED -lt 3 ]]; do
    sleep 3
    ELAPSED=$((ELAPSED + 3))
    
    if [[ -f /tmp/discord-tasks/results.txt ]]; then
        COMPLETED=$(grep -c "SUCCESS\|FAILED" /tmp/discord-tasks/results.txt 2>/dev/null || echo "0")
    fi
    
    printf "\r  %2ds | Completed: %d/3 " $ELAPSED $COMPLETED
    
    [[ $COMPLETED -ge 3 ]] && break
done

printf "\n\n"

# Results
echo "======================================"
echo "Results"
echo "======================================"
echo ""

if [[ -f /tmp/discord-tasks/results.txt ]]; then
    cat /tmp/discord-tasks/results.txt | while IFS='|' read -r TASK_ID WORKER_ID STATUS TIMESTAMP RESULT; do
        echo "✅ $TASK_ID by $WORKER_ID"
    done
else
    echo "No results"
fi

echo ""
echo "======================================"
echo "Cleanup"
echo "======================================"
kill $MANAGER_PID 2>/dev/null || true
sleep 2
pkill -f "worker-discord-curl" 2>/dev/null || true

echo ""
echo "Check Discord #worker-pool and #results channels!"
echo ""
