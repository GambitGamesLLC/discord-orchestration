#!/bin/bash
# test-simple.sh - Simple single-terminal test

cd ~/Documents/GitHub/discord-orchestration
source ./discord-config.env

echo "Killing old workers..."
pkill -f worker-reaction 2>/dev/null || true
sleep 1

echo "Starting worker with explicit env..."
(
  export WORKER_ID="worker-1"
  export BOT_TOKEN="$WORKER1_TOKEN"
  export TASK_QUEUE_CHANNEL="$TASK_QUEUE_CHANNEL"
  export RESULTS_CHANNEL="$RESULTS_CHANNEL"
  export WORKER_POOL_CHANNEL="$WORKER_POOL_CHANNEL"
  export POLL_INTERVAL="3"
  export MAX_IDLE_TIME="60"
  bash ./worker-reaction.sh
) &
PID=$!

echo "Worker started (PID: $PID)"
sleep 3

echo "Submitting task..."
./submit-to-queue.sh "Write hello world in Python"

echo "Waiting 30 seconds..."
sleep 30

echo "Worker log:"
tail -20 /tmp/worker.log 2>/dev/null || echo "No log"

echo ""
echo "Results:"
tail -2 /tmp/discord-tasks/results.txt 2>/dev/null || echo "No results"

kill $PID 2>/dev/null || true
