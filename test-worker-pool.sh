#!/bin/bash
#
# test-worker-pool.sh - Test the Discord worker pool (Phase 0, file-based)
#
# This tests the worker pool without actual Discord integration

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================"
echo "Discord Worker Pool - Phase 0 Test"
echo "======================================"
echo ""

# Cleanup previous runs
rm -rf /tmp/discord-tasks /tmp/discord-workers
echo "✓ Cleaned up previous runs"

# Start worker manager with 2 workers (background)
echo ""
echo "Starting worker pool with 2 workers..."
DISCORD_CHANNEL="test-channel" bash "${SCRIPT_DIR}/worker-manager.sh" --workers 2 --channel test-channel &
MANAGER_PID=$!

# Give workers time to start
sleep 5

echo "✓ Workers started (PID: $MANAGER_PID)"
echo ""

# Submit test tasks
echo "Submitting test tasks..."
bash "${SCRIPT_DIR}/submit-task.sh" \
    "Write a Python function to calculate fibonacci numbers" \
    "openrouter/moonshotai/kimi-k2.5" \
    "low"

sleep 1

bash "${SCRIPT_DIR}/submit-task.sh" \
    "Write a hello world program in JavaScript" \
    "openrouter/moonshotai/kimi-k2.5" \
    "low"

echo "✓ Tasks submitted"
echo ""

# Monitor for results
echo "Monitoring for results (60s timeout)..."
TIMEOUT=60
ELAPSED=0
COMPLETED=0

while [[ $ELAPSED -lt $TIMEOUT ]] && [[ $COMPLETED -lt 2 ]]; do
    if [[ -f /tmp/discord-tasks/results.txt ]]; then
        COMPLETED=$(grep -c "SUCCESS\|FAILED" /tmp/discord-tasks/results.txt 2>/dev/null || echo "0")
    fi
    
    echo "  ${ELAPSED}s: ${COMPLETED}/2 tasks completed"
    
    if [[ $COMPLETED -lt 2 ]]; then
        sleep 5
        ELAPSED=$((ELAPSED + 5))
    fi
done

echo ""
echo "======================================"
echo "Results"
echo "======================================"

if [[ -f /tmp/discord-tasks/results.txt ]]; then
    echo ""
    cat /tmp/discord-tasks/results.txt
else
    echo "No results file found"
fi

echo ""
echo "======================================"
echo "Worker Status Log"
echo "======================================"

if [[ -f /tmp/discord-tasks/status.txt ]]; then
    echo ""
    cat /tmp/discord-tasks/status.txt
fi

echo ""
echo "======================================"
echo "Cleanup"
echo "======================================"

# Stop worker manager
kill $MANAGER_PID 2>/dev/null || true
pkill -f "worker.sh" 2>/dev/null || true

echo "✓ Stopped workers"
echo ""

if [[ $COMPLETED -ge 2 ]]; then
    echo "✅ TEST PASSED: Workers processed tasks successfully"
    exit 0
else
    echo "❌ TEST FAILED: Only ${COMPLETED}/2 tasks completed"
    exit 1
fi
