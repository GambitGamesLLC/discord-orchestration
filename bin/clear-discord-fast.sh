#!/bin/bash
# clear-discord-fast.sh - Fast bulk deletion using bulk-delete API (messages <14 days)
# Note: Bulk delete only works for messages <14 days old, and max 100 per call

set -euo pipefail

cd ~/Documents/GitHub/discord-orchestration
source ./discord-config.env 2>/dev/null || {
    echo "❌ Config not found"
    exit 1
}

# Bulk delete all messages in a channel (uses bulk-delete endpoint for efficiency)
bulk_delete_channel() {
    local CHANNEL_ID="$1"
    local CHANNEL_NAME="$2"
    local TOTAL_DELETED=0
    
    echo "🧹 Clearing #${CHANNEL_NAME}..."
    
    while true; do
        # Get batch of messages (max 100 for bulk delete)
        local MESSAGES_JSON
        MESSAGES_JSON=$(curl -s -H "Authorization: Bot ${ORCHESTRATOR_AGENT_TOKEN}" \
            "https://discord.com/api/v10/channels/${CHANNEL_ID}/messages?limit=100" 2>/dev/null)
        
        # Check if empty
        if [[ -z "$MESSAGES_JSON" ]] || [[ "$MESSAGES_JSON" == "[]" ]] || [[ "$MESSAGES_JSON" == *'"message": "Unknown Channel"'* ]]; then
            break
        fi
        
        # Extract message IDs
        local MSG_IDS
        MSG_IDS=$(echo "$MESSAGES_JSON" | python3 -c "import json,sys; data=json.load(sys.stdin); print('\n'.join([m['id'] for m in data]))" 2>/dev/null)
        
        if [[ -z "$MSG_IDS" ]]; then
            break
        fi
        
        local COUNT=$(echo "$MSG_IDS" | wc -l)
        echo "  Found ${COUNT} messages, deleting..."
        
        # Build JSON array of message IDs (max 100)
        local ID_ARRAY
        ID_ARRAY=$(echo "$MSG_IDS" | python3 -c "import sys; ids=[l.strip() for l in sys.stdin if l.strip()]; print(json.dumps(ids))" 2>/dev/null || echo "[]")
        
        # Bulk delete
        local RESPONSE
        RESPONSE=$(curl -s -X POST \
            -H "Authorization: Bot ${ORCHESTRATOR_AGENT_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"messages\":${ID_ARRAY}}" \
            "https://discord.com/api/v10/channels/${CHANNEL_ID}/messages/bulk-delete" \
            -w "\nHTTP:%{http_code}" 2>/dev/null)
        
        local HTTP_CODE=$(echo "$RESPONSE" | grep -o "HTTP:[0-9]*" | cut -d: -f2)
        
        if [[ "$HTTP_CODE" == "204" ]]; then
            TOTAL_DELETED=$((TOTAL_DELETED + COUNT))
            echo "  ✅ Deleted ${COUNT} messages (bulk)"
        elif [[ "$HTTP_CODE" == "429" ]]; then
            # Rate limited - fall back to individual deletes
            echo "  ⚠️  Rate limited, switching to individual delete..."
            while IFS= read -r MSG_ID; do
                [[ -z "$MSG_ID" ]] && continue
                curl -s -X DELETE \
                    -H "Authorization: Bot ${ORCHESTRATOR_AGENT_TOKEN}" \
                    "https://discord.com/api/v10/channels/${CHANNEL_ID}/messages/${MSG_ID}" \
                    > /dev/null 2>&1 && TOTAL_DELETED=$((TOTAL_DELETED + 1))
                sleep 0.3
            done <<< "$MSG_IDS"
        else
            # Some messages might be >14 days old, try individual delete
            echo "  ⚠️  Bulk delete failed (HTTP ${HTTP_CODE}), trying individual..."
            while IFS= read -r MSG_ID; do
                [[ -z "$MSG_ID" ]] && continue
                local DEL_RESP
                DEL_RESP=$(curl -s -X DELETE \
                    -H "Authorization: Bot ${ORCHESTRATOR_AGENT_TOKEN}" \
                    "https://discord.com/api/v10/channels/${CHANNEL_ID}/messages/${MSG_ID}" \
                    -w "%{http_code}" 2>/dev/null)
                if [[ "$DEL_RESP" == "204" ]]; then
                    TOTAL_DELETED=$((TOTAL_DELETED + 1))
                fi
                sleep 0.3
            done <<< "$MSG_IDS"
        fi
        
        sleep 1  # Rate limit between batches
    done
    
    echo "  ✅ Total deleted from #${CHANNEL_NAME}: ${TOTAL_DELETED}"
}

echo "═══════════════════════════════════════════════════════════"
echo "🧹 DISCORD CHANNEL CLEANUP (Fast Mode)"
echo "═══════════════════════════════════════════════════════════"

bulk_delete_channel "$TASK_QUEUE_CHANNEL" "task-queue"
bulk_delete_channel "$RESULTS_CHANNEL" "results"
bulk_delete_channel "$WORKER_POOL_CHANNEL" "worker-pool"

echo ""
echo "✅ Cleanup complete!"
echo ""

# Clear local files too
> .runtime/assigned-tasks.txt 2>/dev/null || true
rm -rf workers/* 2>/dev/null || true
echo "📝 Local runtime files cleared."
