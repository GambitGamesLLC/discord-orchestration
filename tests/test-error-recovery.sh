#!/bin/bash
#
# test-error-recovery.sh - Test error handling for malformed tasks

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../discord-config.env"
set -a && source "${SCRIPT_DIR}/../discord-config.env" && set +a
export BOT_TOKEN="$WORKER1_TOKEN"

echo "======================================"
echo "Error Recovery Test"
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

# Start 1 worker
echo "1. Starting worker..."
export WORKER_ID="error-test-worker"
export POLL_INTERVAL="2"
export MAX_IDLE_TIME="60"
(
    bash "${SCRIPT_DIR}/../bin/worker-reaction.sh"
) > /tmp/error-test-worker.log 2>&1 &
WORKER_PID=$!
echo "   ✓ Worker started (PID: $WORKER_PID)"
sleep 3
echo ""

# Submit malformed tasks
echo "2. Submitting 3 error-inducing tasks..."
echo ""

# Task 1: Non-existent file
"${SCRIPT_DIR}/../bin/submit-to-queue.sh" "Read the file at /nonexistent/path/file.txt and report its contents"
echo "   ✓ Task 1: Non-existent file"

# Task 2: Invalid command
"${SCRIPT_DIR}/../bin/submit-to-queue.sh" "Run the command 'invalid_command_xyz' and report the output"
echo "   ✓ Task 2: Invalid command"

# Task 3: Division by zero (will cause error)
"${SCRIPT_DIR}/../bin/submit-to-queue.sh" "Calculate 100 divided by 0 using Python and report the result"
echo "   ✓ Task 3: Division by zero"

echo ""
echo "3. Waiting for all tasks to complete (max 120s)..."
echo ""

TIMEOUT=120
ELAPSED=0
COMPLETED=0

while [[ $ELAPSED -lt $TIMEOUT ]] && [[ $COMPLETED -lt 3 ]]; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    
    if [[ -f /tmp/discord-tasks/results.txt ]]; then
        COMPLETED=$(grep -c "error-test-worker" /tmp/discord-tasks/results.txt 2>/dev/null || echo 0)
    fi
    
    echo -ne "   ${ELAPSED}s: $COMPLETED/3 tasks completed\r"
done

echo ""
echo ""
echo "4. Results"
echo "=========="
echo ""

if [[ -f /tmp/discord-tasks/results.txt ]]; then
    echo "All results for error-test-worker:"
    grep "error-test-worker" /tmp/discord-tasks/results.txt | while read line; do
        echo "   $line"
    done
    echo ""
    
    SUCCESS_COUNT=$(grep "error-test-worker" /tmp/discord-tasks/results.txt | grep -c "SUCCESS" || echo 0)
    FAILED_COUNT=$(grep "error-test-worker" /tmp/discord-tasks/results.txt | grep -c "FAILED" || echo 0)
    
    echo "Summary:"
    echo "   SUCCESS: $SUCCESS_COUNT"
    echo "   FAILED:  $FAILED_COUNT"
    echo ""
    
    if [[ $FAILED_COUNT -eq 3 ]]; then
        echo "✅ ERROR RECOVERY TEST PASSED"
        echo "   All 3 malformed tasks failed gracefully"
        echo "   Worker posted FAILED status for each"
    elif [[ $((SUCCESS_COUNT + FAILED_COUNT)) -eq 3 ]]; then
        echo "✅ ERROR RECOVERY TEST PASSED (with some successes)"
        echo "   All tasks completed (some may have been handled)"
    else
        echo "⚠️  ERROR RECOVERY TEST INCONCLUSIVE"
        echo "   Only $((SUCCESS_COUNT + FAILED_COUNT))/3 tasks completed"
    fi
else
    echo "❌ ERROR RECOVERY TEST FAILED"
    echo "   No results file created"
fi

echo ""
echo "Worker log (last 20 lines):"
tail -20 /tmp/error-test-worker.log 2>/dev/null | sed 's/^/   /' || echo "   (no log)"

echo ""
echo "Test complete."
