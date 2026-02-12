#!/bin/bash
# clear-task-queue.sh - Delete all messages from #task-queue

cd ~/Documents/GitHub/discord-orchestration
source ./discord-config.env 2>/dev/null || {
    echo "Config not found"
    exit 1
}

echo "Fetching messages from #task-queue..."

MESSAGES=$(curl -s -H "Authorization: Bot ${ORCHESTRATOR_AGENT_TOKEN}" \
    "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL}/messages?limit=100")

MSG_COUNT=$(echo "$MESSAGES" | grep -o '"id":"[0-9]*"' | wc -l)
echo "Found $MSG_COUNT messages"

if [[ $MSG_COUNT -eq 0 ]]; then
    echo "Channel is already empty"
    exit 0
fi

echo "Deleting messages..."

echo "$MESSAGES" | grep -o '"id":"[0-9]*"' | sed 's/"id":"//;s/"$//' | while read -r MSG_ID; do
    echo -n "."
    curl -s -X DELETE \
        -H "Authorization: Bot ${ORCHESTRATOR_AGENT_TOKEN}" \
        "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL}/messages/${MSG_ID}" \
        > /dev/null 2>&1
    sleep 0.5  # Rate limit protection
done

echo ""
echo "✅ Channel cleared"
