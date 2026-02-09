#!/bin/bash
# test-enhanced-reporting.sh - Test the enhanced reporting features

cd ~/Documents/GitHub/discord-orchestration
source ./discord-config.env

echo "=== Testing Enhanced Reporting ==="
echo ""

# Clear queue
./bin/clear-task-queue.sh > /dev/null 2>&1
echo "✓ Queue cleared"
echo ""

# Submit task with model and thinking
echo "Submitting task with model and thinking specified..."
./bin/submit-to-queue.sh "Calculate fibonacci sequence" "claude-sonnet-4" "high"
echo ""

# Run worker once
export WORKER_ID="worker-1"
export BOT_TOKEN="$WORKER1_TOKEN"
export TASK_QUEUE_CHANNEL="$TASK_QUEUE_CHANNEL"
export RESULTS_CHANNEL="$RESULTS_CHANNEL"
export WORKER_POOL_CHANNEL="$WORKER_POOL_CHANNEL"
export POLL_INTERVAL="2"
export MAX_IDLE_TIME="60"

echo "Running worker..."
timeout 45 ./bin/worker-reaction.sh 2>&1 | tee /tmp/enhanced-test.log

echo ""
echo "=== Results ==="
echo ""
echo "Status log (should show model/thinking):"
grep "CLAIMED\|RESTARTING" /tmp/discord-tasks/status.txt | tail -3

echo ""
echo "Result log (should show model/thinking/tokens):"
tail -1 /tmp/discord-tasks/results.txt

echo ""
echo "Check Discord #results for the enhanced message format!"
