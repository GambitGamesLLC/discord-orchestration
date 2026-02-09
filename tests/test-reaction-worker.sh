#!/bin/bash
#
# test-reaction-worker.sh - Test reaction-based task claiming

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/discord-config.env" ]]; then
    source "${SCRIPT_DIR}/discord-config.env"
fi

echo "======================================"
echo "Reaction-Based Worker Test"
echo "======================================"
echo ""

# Cleanup
pkill -f "worker-reaction" 2>/dev/null || true
rm -rf /tmp/discord-workers
mkdir -p /tmp/discord-tasks
sleep 1

echo "Starting Worker-1..."
export WORKER_ID="worker-1"
export BOT_TOKEN="${WORKER1_TOKEN:-}"
export TASK_QUEUE_CHANNEL="${TASK_QUEUE_CHANNEL:-}"
export RESULTS_CHANNEL="${RESULTS_CHANNEL:-}"
export WORKER_POOL_CHANNEL="${WORKER_POOL_CHANNEL:-}"
export POLL_INTERVAL="3"
export MAX_IDLE_TIME="60"

timeout 90 bash "${SCRIPT_DIR}/worker-reaction.sh" > /tmp/worker1.log 2>&1 &
WORKER_PID=$!

echo "✅ Worker-1 started (PID: $WORKER_PID)"
echo ""

sleep 3

echo "Submitting test task to Discord #task-queue..."
./submit-to-queue.sh "Write a hello world program in Python"

echo ""
echo "Monitoring for 60 seconds..."
echo "Watch #worker-pool for status and #results for output"
echo ""

TIMEOUT=60
ELAPSED=0
COMPLETED=0

while [[ $ELAPSED -lt $TIMEOUT ]] && [[ $COMPLETED -lt 1 ]]; do
    sleep 3
    ELAPSED=$((ELAPSED + 3))
    
    if [[ -f /tmp/discord-tasks/results.txt ]]; then
        COMPLETED=$(grep -c "SUCCESS\|FAILED" /tmp/discord-tasks/results.txt 2>/dev/null || echo "0")
    fi
    
    printf "\r  %2ds elapsed... " $ELAPSED
done

printf "\n\n"

if [[ $COMPLETED -ge 1 ]]; then
    echo "✅ Task completed!"
    echo ""
    echo "Result:"
    tail -1 /tmp/discord-tasks/results.txt
else
    echo "⚠️  Timeout - check logs: /tmp/worker1.log"
fi

echo ""
kill $WORKER_PID 2>/dev/null || true
