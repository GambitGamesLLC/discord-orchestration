#!/bin/bash
# test-clean.sh - Clean test with message counting

cd ~/Documents/GitHub/discord-orchestration
source ./discord-config.env

echo "=== Clean Test ==="
echo ""

# Count messages before
echo "Messages in #task-queue before test:"
curl -s -H "Authorization: Bot ${CHIP_TOKEN}" \
    "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL}/messages?limit=10" | \
    grep -o '"id":"[0-9]*"' | wc -l
echo ""

# Kill old workers
pkill -f worker-reaction 2>/dev/null || true
sleep 1

# Start worker
echo "Starting worker..."
(
  export WORKER_ID="worker-1"
  export BOT_TOKEN="$WORKER1_TOKEN"
  export TASK_QUEUE_CHANNEL="$TASK_QUEUE_CHANNEL"
  export RESULTS_CHANNEL="$RESULTS_CHANNEL"
  export WORKER_POOL_CHANNEL="$WORKER_POOL_CHANNEL"
  export POLL_INTERVAL="3"
  export MAX_IDLE_TIME="60"
  bash ./worker-reaction.sh 2>&1 | tee /tmp/worker-clean.log
) &
PID=$!

echo "Worker PID: $PID"
sleep 3

# Submit ONE task
echo ""
echo "Submitting ONE task..."
./submit-to-queue.sh "Test task $(date +%s)"

echo ""
echo "Waiting 20 seconds..."
sleep 20

# Count messages after
echo ""
echo "Messages in #task-queue after test:"
curl -s -H "Authorization: Bot ${CHIP_TOKEN}" \
    "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL}/messages?limit=10" | \
    grep -o '"id":"[0-9]*"' | wc -l

echo ""
echo "Task messages:"
curl -s -H "Authorization: Bot ${CHIP_TOKEN}" \
    "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL}/messages?limit=10" | \
    grep -o '"content":"[^"]*"' | sed 's/"content":"//;s/"$//'

# Cleanup
kill $PID 2>/dev/null || true

echo ""
echo "Done. Check if there's more than 1 message."
