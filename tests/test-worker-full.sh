#!/bin/bash
#
# test-worker-full.sh - Single terminal test: start worker, submit task, monitor

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# CRITICAL: Load config here
if [[ -f "${SCRIPT_DIR}/discord-config.env" ]]; then
    source "${SCRIPT_DIR}/discord-config.env"
fi

# Verify tokens loaded
if [[ -z "${WORKER1_TOKEN:-}" ]]; then
    echo "❌ WORKER1_TOKEN not loaded from discord-config.env"
    exit 1
fi

echo "======================================"
echo "Single-Terminal Worker Test"
echo "======================================"
echo ""

# Cleanup
echo "1. Cleaning up..."
pkill -f "worker-reaction\|worker-discord" 2>/dev/null || true
rm -rf /tmp/discord-tasks /tmp/discord-workers
mkdir -p /tmp/discord-tasks
sleep 1
echo "   ✓ Clean"
echo ""

# Write env to temp file for worker
ENV_FILE="/tmp/worker-env.sh"
cat > "$ENV_FILE" << EOF
WORKER_ID="worker-1"
BOT_TOKEN="${WORKER1_TOKEN}"
TASK_QUEUE_CHANNEL="${TASK_QUEUE_CHANNEL}"
RESULTS_CHANNEL="${RESULTS_CHANNEL}"
WORKER_POOL_CHANNEL="${WORKER_POOL_CHANNEL}"
POLL_INTERVAL="3"
MAX_IDLE_TIME="120"
EOF

echo "2. Starting Worker-1..."
(
    source "$ENV_FILE"
    bash "${SCRIPT_DIR}/worker-reaction.sh"
) > /tmp/worker.log 2>&1 &
WORKER_PID=$!

sleep 3
echo "   ✓ Worker started (PID: $WORKER_PID)"
echo ""

# Submit task
echo "3. Submitting test task..."
./submit-to-queue.sh "Write a hello world program in Python"
echo ""

# Monitor
echo "4. Monitoring for 90 seconds..."
echo ""
TIMEOUT=90
ELAPSED=0
COMPLETED=0

while [[ $ELAPSED -lt $TIMEOUT ]] && [[ $COMPLETED -lt 1 ]]; do
    clear
    echo "======================================"
    echo "Worker Monitor - ${ELAPSED}s elapsed"
    echo "======================================"
    echo ""
    
    echo "--- Worker Log (last 15 lines) ---"
    tail -15 /tmp/worker.log 2>/dev/null || echo "No log yet..."
    
    echo ""
    echo "--- Results ---"
    if [[ -f /tmp/discord-tasks/results.txt ]]; then
        COMPLETED=$(grep -c "SUCCESS\|FAILED" /tmp/discord-tasks/results.txt)
        tail -2 /tmp/discord-tasks/results.txt
    else
        echo "No results yet..."
    fi
    
    echo ""
    echo "--- Status ---"
    if [[ -f /tmp/discord-tasks/status.txt ]]; then
        tail -3 /tmp/discord-tasks/status.txt
    fi
    
    if [[ $COMPLETED -ge 1 ]]; then
        echo ""
        echo "✅ TASK COMPLETED!"
        break
    fi
    
    sleep 3
    ELAPSED=$((ELAPSED + 3))
done

# Cleanup
echo ""
echo "5. Cleanup..."
kill $WORKER_PID 2>/dev/null || true
rm -f "$ENV_FILE"
sleep 1

echo ""
if [[ $COMPLETED -ge 1 ]]; then
    echo "✅ SUCCESS! Check Discord #results for full output"
else
    echo "⚠️  Timeout or no task found"
    echo ""
    echo "Debug - Last 50 lines of worker log:"
    tail -50 /tmp/worker.log
fi

echo ""
