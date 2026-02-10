#!/bin/bash
#
# test-long-running.sh - Test timeout behavior with long tasks

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../discord-config.env"
set -a && source "${SCRIPT_DIR}/../discord-config.env" && set +a
export BOT_TOKEN="$WORKER1_TOKEN"

echo "======================================"
echo "Long-Running Task Test (Timeout)"
echo "======================================"
echo ""

# Cleanup
rm -f /tmp/discord-tasks/results.txt 2>/dev/null || true

cleanup() {
    echo ""
    echo "Cleaning up..."
    kill $WORKER_PID 2>/dev/null || true
}
trap cleanup EXIT

# Start 1 worker with shorter timeout
echo "1. Starting worker with 60s max idle..."
export WORKER_ID="longrun-test-worker"
export POLL_INTERVAL="2"
export MAX_IDLE_TIME="60"
(
    bash "${SCRIPT_DIR}/../bin/worker-reaction.sh"
) > /tmp/longrun-worker.log 2>&1 &
WORKER_PID=$!
echo "   ✓ Worker started (PID: $WORKER_PID)"
sleep 3
echo ""

# Submit a 90-second task (longer than default 120s agent timeout)
echo "2. Submitting 90-second task..."
"${SCRIPT_DIR}/../bin/submit-to-queue.sh" "Count from 1 to 90 with 'sleep 1' between each number, writing progress to a file at /tmp/longrun-progress.txt. Report the final count."

echo ""
echo "3. Monitoring for 150 seconds..."
echo "   (Task: 90s, Agent timeout: 120s, Max wait: 150s)"
echo ""

TIMEOUT=150
ELAPSED=0
RESULT=""

while [[ $ELAPSED -lt $TIMEOUT ]]; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    
    # Check progress file
    if [[ -f /tmp/longrun-progress.txt ]]; then
        LAST_LINE=$(tail -1 /tmp/longrun-progress.txt 2>/dev/null | head -c 50)
        echo -ne "   ${ELAPSED}s: $LAST_LINE\r"
    fi
    
    # Check if result logged
    if [[ -f /tmp/discord-tasks/results.txt ]]; then
        RESULT=$(grep "longrun-test-worker" /tmp/discord-tasks/results.txt | tail -1 || echo "")
        if [[ -n "$RESULT" ]]; then
            echo ""
            echo "   ✓ Task completed at ${ELAPSED}s"
            break
        fi
    fi
done

echo ""
echo "4. Results"
echo "=========="
echo ""

if [[ -n "$RESULT" ]]; then
    echo "Worker result:"
    echo "   $RESULT"
    echo ""
    
    # Check if it succeeded or failed
    if echo "$RESULT" | grep -q "SUCCESS"; then
        echo "✅ Long-running test: Task completed successfully"
    elif echo "$RESULT" | grep -q "FAILED"; then
        echo "⚠️  Long-running test: Task failed (likely timeout)"
    else
        echo "? Unknown result status"
    fi
else
    echo "❌ Long-running test: No result after ${TIMEOUT}s"
fi

# Check progress file
echo ""
echo "Progress file contents:"
if [[ -f /tmp/longrun-progress.txt ]]; then
    wc -l /tmp/longrun-progress.txt | awk '{print "   Lines written: " $1}'
    echo "   Last 3 lines:"
    tail -3 /tmp/longrun-progress.txt | sed 's/^/      /'
else
    echo "   (no progress file created)"
fi

# Cleanup
rm -f /tmp/longrun-progress.txt 2>/dev/null || true

echo ""
echo "Test complete."
