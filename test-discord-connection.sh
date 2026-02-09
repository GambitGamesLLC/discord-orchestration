#!/bin/bash
#
# test-discord-connection.sh - Test Discord bot connectivity

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config
if [[ ! -f "${SCRIPT_DIR}/discord-config.env" ]]; then
    echo "❌ Config file not found: ${SCRIPT_DIR}/discord-config.env"
    echo "Run ./setup-discord.sh first"
    exit 1
fi

source "${SCRIPT_DIR}/discord-config.env"

echo "======================================"
echo "Discord Connection Test"
echo "======================================"
echo ""

# Test 1: Check config loaded
echo "1. Checking configuration..."
[[ -n "$CHIP_TOKEN" ]] && echo "   ✅ Chip token loaded" || echo "   ❌ Chip token missing"
[[ -n "$WORKER1_TOKEN" ]] && echo "   ✅ Worker-1 token loaded" || echo "   ❌ Worker-1 token missing"
[[ -n "$WORKER2_TOKEN" ]] && echo "   ✅ Worker-2 token loaded" || echo "   ❌ Worker-2 token missing"
[[ -n "$WORKER3_TOKEN" ]] && echo "   ✅ Worker-3 token loaded" || echo "   ❌ Worker-3 token missing"
[[ -n "$GUILD_ID" ]] && echo "   ✅ Guild ID loaded" || echo "   ❌ Guild ID missing"
echo ""

# Test 2: Try posting a message via OpenClaw
echo "2. Testing message send..."
echo "   Sending test message to #worker-pool..."

if openclaw message send \
    --channel discord \
    --to "${WORKER_POOL_CHANNEL}" \
    --message "🧪 **Connection Test**\nChip is testing Discord integration!\n$(date)" \
    2>/dev/null; then
    echo "   ✅ Message sent successfully!"
else
    echo "   ❌ Failed to send message"
    echo "   Check your Discord token and channel permissions"
fi
echo ""

# Test 3: Show config summary
echo "3. Configuration Summary"
echo "   Chip Token: ${CHIP_TOKEN:0:10}..."
echo "   Server ID: ${GUILD_ID}"
echo "   Task Queue: ${TASK_QUEUE_CHANNEL}"
echo "   Results: ${RESULTS_CHANNEL}"
echo "   Worker Pool: ${WORKER_POOL_CHANNEL}"
echo ""

echo "======================================"
echo "Next Steps"
echo "======================================"
echo ""
echo "If message sent successfully:"
echo "  1. Check #worker-pool for the test message"
echo "  2. Start workers: ./worker-manager-discord.sh"
echo "  3. Submit task: ./orchestrator-discord.sh --task 'Your task'"
echo ""
echo "If message failed:"
echo "  1. Verify bot is in the server"
echo "  2. Check bot has 'Send Messages' permission"
echo "  3. Regenerate token if needed"
echo ""
