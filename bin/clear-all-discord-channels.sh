#!/bin/bash
# clear-all-discord-channels.sh - Delete ALL messages from all Discord orchestration channels
# This clears #task-queue, #results, and #worker-pool

set -euo pipefail

cd ~/Documents/GitHub/discord-orchestration
source ./discord-config.env 2>/dev/null || {
    echo "❌ Config not found at ./discord-config.env"
    exit 1
}

# Check for bot token
if [[ -z "${ORCHESTRATOR_AGENT_TOKEN:-}" ]]; then
    echo "❌ ORCHESTRATOR_AGENT_TOKEN not set"
    exit 1
fi

# Channel names (for display)
declare -A CHANNEL_NAMES
CHANNEL_NAMES[$TASK_QUEUE_CHANNEL]="task-queue"
CHANNEL_NAMES[$RESULTS_CHANNEL]="results"
CHANNEL_NAMES[$WORKER_POOL_CHANNEL]="worker-pool"

# Function to count messages in a channel
count_messages() {
    local CHANNEL_ID="$1"
    local MESSAGES
    MESSAGES=$(curl -s -H "Authorization: Bot ${ORCHESTRATOR_AGENT_TOKEN}" \
        "https://discord.com/api/v10/channels/${CHANNEL_ID}/messages?limit=100" 2>/dev/null)
    
    if [[ -z "$MESSAGES" ]] || [[ "$MESSAGES" == "[]" ]]; then
        echo "0"
        return
    fi
    
    echo "$MESSAGES" | grep -o '"id":"[0-9]*"' | wc -l
}

# Function to delete all messages in a channel (with pagination for >100 messages)
delete_all_messages() {
    local CHANNEL_ID="$1"
    local CHANNEL_NAME="${CHANNEL_NAMES[$CHANNEL_ID]:-unknown}"
    local TOTAL_DELETED=0
    local BATCH=0
    
    echo ""
    echo "🧹 Clearing #${CHANNEL_NAME} (${CHANNEL_ID})..."
    
    # Loop until no more messages (handles >100 messages via pagination)
    while true; do
        BATCH=$((BATCH + 1))
        
        # Fetch messages (100 per request)
        local MESSAGES
        MESSAGES=$(curl -s -H "Authorization: Bot ${ORCHESTRATOR_AGENT_TOKEN}" \
            "https://discord.com/api/v10/channels/${CHANNEL_ID}/messages?limit=100" 2>/dev/null)
        
        # Check if empty or error
        if [[ -z "$MESSAGES" ]] || [[ "$MESSAGES" == "[]" ]]; then
            break
        fi
        
        # Extract message IDs
        local MSG_IDS
        MSG_IDS=$(echo "$MESSAGES" | grep -o '"id":"[0-9]*"' | sed 's/"id":"//;s/"$//')
        
        if [[ -z "$MSG_IDS" ]]; then
            break
        fi
        
        local BATCH_COUNT=$(echo "$MSG_IDS" | wc -l)
        echo "  Batch ${BATCH}: Deleting ${BATCH_COUNT} messages..."
        
        # Delete each message
        local BATCH_DELETED=0
        while IFS= read -r MSG_ID; do
            [[ -z "$MSG_ID" ]] && continue
            
            local RESPONSE
            RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE \
                -H "Authorization: Bot ${ORCHESTRATOR_AGENT_TOKEN}" \
                "https://discord.com/api/v10/channels/${CHANNEL_ID}/messages/${MSG_ID}" 2>/dev/null)
            
            local HTTP_CODE=$(echo "$RESPONSE" | tail -1)
            
            if [[ "$HTTP_CODE" == "204" ]] || [[ "$HTTP_CODE" == "200" ]]; then
                BATCH_DELETED=$((BATCH_DELETED + 1))
                TOTAL_DELETED=$((TOTAL_DELETED + 1))
                echo -n "."
            elif [[ "$HTTP_CODE" == "429" ]]; then
                # Rate limited - wait and retry
                echo -n "R"
                sleep 2
                # Retry once
                RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE \
                    -H "Authorization: Bot ${ORCHESTRATOR_AGENT_TOKEN}" \
                    "https://discord.com/api/v10/channels/${CHANNEL_ID}/messages/${MSG_ID}" 2>/dev/null)
                HTTP_CODE=$(echo "$RESPONSE" | tail -1)
                if [[ "$HTTP_CODE" == "204" ]] || [[ "$HTTP_CODE" == "200" ]]; then
                    BATCH_DELETED=$((BATCH_DELETED + 1))
                    TOTAL_DELETED=$((TOTAL_DELETED + 1))
                    echo -n "."
                fi
            elif [[ "$HTTP_CODE" == "403" ]]; then
                echo -n "X"  # No permission
            else
                echo -n "?"  # Unknown error
            fi
            
            # Rate limit: max ~5 deletes per second to be safe
            sleep 0.25
        done <<< "$MSG_IDS"
        
        echo " (${BATCH_DELETED}/${BATCH_COUNT})"
        
        # If we got fewer than 100 messages, we're done
        if [[ $BATCH_COUNT -lt 100 ]]; then
            break
        fi
        
        # Small pause between batches
        sleep 1
    done
    
    echo "  ✅ Deleted ${TOTAL_DELETED} messages from #${CHANNEL_NAME}"
}

# Main
echo "═══════════════════════════════════════════════════════════"
echo "🧹 DISCORD CHANNEL CLEANUP"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "This will delete ALL messages from:"
echo "  • #task-queue"
echo "  • #results"
echo "  • #worker-pool"
echo ""

# Count before cleanup
echo "📊 Current message counts:"
TASK_COUNT=$(count_messages "$TASK_QUEUE_CHANNEL")
RESULTS_COUNT=$(count_messages "$RESULTS_CHANNEL")
WORKER_COUNT=$(count_messages "$WORKER_POOL_CHANNEL")
echo "  • #task-queue: ${TASK_COUNT} messages"
echo "  • #results: ${RESULTS_COUNT} messages"
echo "  • #worker-pool: ${WORKER_COUNT} messages"
echo ""

TOTAL=$((TASK_COUNT + RESULTS_COUNT + WORKER_COUNT))
if [[ $TOTAL -eq 0 ]]; then
    echo "✅ All channels are already empty!"
    exit 0
fi

# Confirm
echo "Total messages to delete: ${TOTAL}"
echo ""
read -p "⚠️  Are you sure you want to delete all messages? (yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    echo "❌ Cancelled"
    exit 0
fi

echo ""
echo "🗑️  Starting cleanup..."

# Delete from each channel
delete_all_messages "$TASK_QUEUE_CHANNEL"
delete_all_messages "$RESULTS_CHANNEL"
delete_all_messages "$WORKER_POOL_CHANNEL"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "✅ CLEANUP COMPLETE"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "All Discord orchestration channels have been cleared."
echo ""

# Also clear local runtime files
if [[ -f ".runtime/assigned-tasks.txt" ]]; then
    > .runtime/assigned-tasks.txt
    echo "📝 Cleared: .runtime/assigned-tasks.txt"
fi

# Clean workers directory
if [[ -d "workers" ]]; then
    rm -rf workers/*
    echo "📝 Cleaned: workers/ directory"
fi

echo ""
echo "Ready for fresh orchestration cycle!"
