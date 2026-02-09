#!/bin/bash
#
# debug-worker.sh - Debug Discord polling

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/discord-config.env" ]]; then
    source "${SCRIPT_DIR}/discord-config.env"
fi

echo "======================================"
echo "Worker Debug Tool"
echo "======================================"
echo ""

if [[ -z "${WORKER1_TOKEN:-}" ]]; then
    echo "❌ WORKER1_TOKEN not set"
    exit 1
fi

export BOT_TOKEN="$WORKER1_TOKEN"

echo "Testing Discord API connection..."

# Test 1: Get channel info
echo ""
echo "Test 1: Getting channel info..."
CHANNEL_INFO=$(curl -s -H "Authorization: Bot ${BOT_TOKEN}" \
    "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL:-}" 2>/dev/null)

if echo "$CHANNEL_INFO" | grep -q "${TASK_QUEUE_CHANNEL:-}"; then
    echo "✅ Channel accessible: $(echo "$CHANNEL_INFO" | grep -o '"name":"[^"]*"' || echo '(unknown name)')"
else
    echo "❌ Channel access failed: ${CHANNEL_INFO:0:200}"
fi

# Test 2: Get messages
echo ""
echo "Test 2: Getting messages from #task-queue..."
MESSAGES=$(curl -s -H "Authorization: Bot ${BOT_TOKEN}" \
    "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL:-}/messages?limit=10" 2>/dev/null)

MSG_COUNT=$(echo "$MESSAGES" | grep -o '"id":"[0-9]*"' | wc -l)
echo "Found $MSG_COUNT recent messages"

if [[ $MSG_COUNT -gt 0 ]]; then
    echo ""
    echo "Latest message preview:"
    echo "$MESSAGES" | grep '"content":"' | head -1 | cut -d'"' -f4 | head -c 100
    echo ""
fi

# Test 3: Try to add reaction to a message
echo ""
echo "Test 3: Trying to add reaction..."

LATEST_MSG=$(echo "$MESSAGES" | grep -o '"id":"[0-9]*"' | head -1 | sed 's/"id":"//;s/"$//')

if [[ -n "$LATEST_MSG" ]]; then
    echo "Latest message ID: ${LATEST_MSG:0:15}..."
    
    REACTION_RESPONSE=$(curl -s -X PUT \
        -H "Authorization: Bot ${BOT_TOKEN}" \
        "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL:-}/messages/${LATEST_MSG}/reactions/%E2%9C%85/@me" 2>/dev/null)
    
    if [[ -z "$REACTION_RESPONSE" ]]; then
        echo "✅ Successfully added reaction!"
        
        # Clean up - remove the test reaction
        curl -s -X DELETE \
            -H "Authorization: Bot ${BOT_TOKEN}" \
            "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL:-}/messages/${LATEST_MSG}/reactions/%E2%9C%85/@me" 2>/dev/null || true
    else
        echo "❌ Reaction failed: ${REACTION_RESPONSE:0:200}"
    fi
else
    echo "⚠️  No messages to react to"
fi

echo ""
echo "======================================"
echo "Debug complete"
echo "======================================"
