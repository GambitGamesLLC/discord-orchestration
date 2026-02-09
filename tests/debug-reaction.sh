#!/bin/bash
# debug-reaction.sh - Debug reaction claiming step by step

cd ~/Documents/GitHub/discord-orchestration
source ./discord-config.env

echo "=== Debug Reaction Claiming ==="
echo ""

# Clear channel first
echo "1. Clearing #task-queue..."
./clear-task-queue.sh > /dev/null 2>&1
sleep 1
echo "   Done"
echo ""

# Post a task
echo "2. Posting test task as Chip..."
TEST_MSG="Debug task $(date +%s)"
CHIP_RESPONSE=$(curl -s -X POST \
    -H "Authorization: Bot ${CHIP_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"content\":\"${TEST_MSG}\"}" \
    "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL}/messages")

MSG_ID=$(echo "$CHIP_RESPONSE" | grep -o '"id":"[0-9]*"' | head -1 | sed 's/"id":"//;s/"$//')
echo "   Posted message ID: ${MSG_ID:0:15}..."
echo ""

# Wait a moment
sleep 2

# Start worker in foreground with debug
echo "3. Starting worker with DEBUG output..."
echo "   (Watch for 'Attempting to claim' and '✅ Claimed' messages)"
echo ""

export WORKER_ID="worker-1"
export BOT_TOKEN="$WORKER1_TOKEN"
export TASK_QUEUE_CHANNEL="$TASK_QUEUE_CHANNEL"
export RESULTS_CHANNEL="$RESULTS_CHANNEL"
export WORKER_POOL_CHANNEL="$WORKER_POOL_CHANNEL"
export POLL_INTERVAL="2"
export MAX_IDLE_TIME="30"

# Run worker once (will exit after task)
timeout 45 bash ./worker-reaction.sh 2>&1 | tee /tmp/debug-reaction.log

echo ""
echo "=== Results ==="
echo ""

# Check reactions on the message
echo "4. Checking reactions on message ${MSG_ID:0:15}..."
REACTIONS=$(curl -s -H "Authorization: Bot ${CHIP_TOKEN}" \
    "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL}/messages/${MSG_ID}/reactions/%E2%9C%85")

REACTION_COUNT=$(echo "$REACTIONS" | grep -o '"id":"[0-9]*"' | wc -l)
echo "   ✅ reactions found: $REACTION_COUNT"

if [[ $REACTION_COUNT -gt 0 ]]; then
    echo "   Reactors:"
    echo "$REACTIONS" | grep -o '"username":"[^"]*"' | sed 's/"username":"//;s/"$/   - /'
fi

echo ""
echo "5. Worker log excerpt:"
grep -E "Attempting|Claimed|RESTARTING" /tmp/debug-reaction.log | head -5

echo ""
echo "Check Discord #task-queue - you should see:"
echo "  - Your task message"
echo "  - A ✅ reaction on it (from worker-1)"
echo ""
