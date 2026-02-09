#!/bin/bash
#
# test-reaction-permissions.sh - Test if workers can react to Chip's messages

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config
if [[ -f "${SCRIPT_DIR}/discord-config.env" ]]; then
    source "${SCRIPT_DIR}/discord-config.env"
fi

echo "======================================"
echo "Discord Reaction Permissions Test"
echo "======================================"
echo ""

if [[ -z "$CHIP_TOKEN" || -z "$WORKER1_TOKEN" || -z "$TASK_QUEUE_CHANNEL" ]]; then
    echo "❌ Missing config. Run ./setup-discord.sh first"
    exit 1
fi

echo "Step 1: Chip posts a test message to #task-queue..."

TEST_MSG="Test message for reaction permissions $(date +%s)"

# Chip posts message
CHIP_RESPONSE=$(curl -s -X POST \
    -H "Authorization: Bot ${CHIP_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"content\":\"${TEST_MSG}\"}" \
    "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL}/messages")

if ! echo "$CHIP_RESPONSE" | grep -q '"id"'; then
    echo "❌ Chip failed to post message"
    echo "Response: ${CHIP_RESPONSE:0:200}"
    exit 1
fi

MSG_ID=$(echo "$CHIP_RESPONSE" | grep -o '"id":"[0-9]*"' | head -1 | sed 's/"id":"//;s/"$//')
echo "✅ Chip posted message (ID: ${MSG_ID:0:15}...)"
echo ""

echo "Step 2: Worker-1 tries to add ✅ reaction..."

# Worker-1 tries to add reaction
WORKER_RESPONSE=$(curl -s -X PUT \
    -H "Authorization: Bot ${WORKER1_TOKEN}" \
    "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL}/messages/${MSG_ID}/reactions/%E2%9C%85/@me")

# Check response (empty response = success)
if [[ -z "$WORKER_RESPONSE" ]]; then
    echo "✅ Worker-1 successfully added reaction!"
    REACTION_SUCCESS=true
elif echo "$WORKER_RESPONSE" | grep -q "403\|Unauthorized\|Forbidden"; then
    echo "❌ Worker-1 cannot add reaction (permission denied)"
    echo "Error: ${WORKER_RESPONSE:0:200}"
    REACTION_SUCCESS=false
else
    echo "⚠️  Unexpected response: ${WORKER_RESPONSE:0:200}"
    REACTION_SUCCESS=false
fi

echo ""

echo "Step 3: Worker-2 tries to add reaction to same message..."

WORKER2_RESPONSE=$(curl -s -X PUT \
    -H "Authorization: Bot ${WORKER2_TOKEN}" \
    "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL}/messages/${MSG_ID}/reactions/%E2%9C%85/@me")

if [[ -z "$WORKER2_RESPONSE" ]]; then
    echo "✅ Worker-2 can also add reaction (multiple reactions allowed)"
elif echo "$WORKER2_RESPONSE" | grep -q "403\|Unauthorized\|Forbidden"; then
    echo "❌ Worker-2 cannot add reaction"
else
    echo "Response: ${WORKER2_RESPONSE:0:100}"
fi

echo ""

echo "Step 4: Cleanup - deleting test message..."

# Chip deletes the test message
DELETE_RESPONSE=$(curl -s -X DELETE \
    -H "Authorization: Bot ${CHIP_TOKEN}" \
    "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL}/messages/${MSG_ID}")

if [[ -z "$DELETE_RESPONSE" ]]; then
    echo "✅ Test message deleted"
else
    echo "⚠️  Delete response: ${DELETE_RESPONSE:0:100}"
fi

echo ""
echo "======================================"
echo "Test Results"
echo "======================================"
echo ""

if [[ "$REACTION_SUCCESS" == "true" ]]; then
    echo "✅ REACTION-BASED CLAIMING WILL WORK!"
    echo ""
    echo "Implementation plan:"
    echo "1. You post task to #task-queue"
    echo "2. Workers poll and fetch messages"
    echo "3. Worker tries to add ✅ reaction"
    echo "   - If SUCCESS: Worker claims task, executes"
    echo "   - If FAILS: Another worker claimed it, skip"
    echo "4. Task stays visible with ✅ reaction"
    echo "5. Worker adds 🔄 when starting, ✅ when done"
    echo ""
    echo "This prevents race conditions!"
else
    echo "❌ Reactions won't work - need different approach"
    echo "Options:"
    echo "  1. File-based queue (current, reliable)"
    echo "  2. Chip assigns tasks via DMs"
    echo "  3. Database/Redis queue"
fi

echo ""
