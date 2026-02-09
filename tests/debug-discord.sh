#!/bin/bash
#
# debug-discord.sh - Debug Discord connection issues

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "${SCRIPT_DIR}/discord-config.env" ]]; then
    echo "❌ Config not found"
    exit 1
fi

source "${SCRIPT_DIR}/discord-config.env"

echo "======================================"
echo "Discord Debug Tool"
echo "======================================"
echo ""

# Check if bot is in server using gateway API
echo "1. Testing Discord API connectivity..."

# Try to get bot info
BOT_INFO=$(curl -s -H "Authorization: Bot ${CHIP_TOKEN}" \
    https://discord.com/api/v10/users/@me 2>/dev/null || echo "")

if [[ -n "$BOT_INFO" ]] && echo "$BOT_INFO" | grep -q "id"; then
    BOT_ID=$(echo "$BOT_INFO" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    BOT_NAME=$(echo "$BOT_INFO" | grep -o '"username":"[^"]*"' | cut -d'"' -f4)
    echo "   ✅ Bot authenticated: ${BOT_NAME} (ID: ${BOT_ID})"
else
    echo "   ❌ Bot authentication failed"
    echo "   Response: ${BOT_INFO}"
    echo ""
    echo "Possible causes:"
    echo "  - Invalid token"
    echo "  - Token was reset but not updated in config"
    exit 1
fi
echo ""

# Check guild membership
echo "2. Checking server membership..."
GUILDS=$(curl -s -H "Authorization: Bot ${CHIP_TOKEN}" \
    https://discord.com/api/v10/users/@me/guilds 2>/dev/null || echo "")

if echo "$GUILDS" | grep -q "${GUILD_ID}"; then
    echo "   ✅ Bot is in server ${GUILD_ID}"
else
    echo "   ❌ Bot is NOT in server ${GUILD_ID}"
    echo "   Guilds found: $(echo "$GUILDS" | grep -o '"id":"[^"]*"' | head -5 | cut -d'"' -f4)"
    echo ""
    echo "Fix: Re-invite bot to server using:"
    echo "https://discord.com/api/oauth2/authorize?client_id=${BOT_ID}&permissions=274877910016&scope=bot"
    exit 1
fi
echo ""

# Check channel access
echo "3. Checking channel access..."
CHANNEL=$(curl -s -H "Authorization: Bot ${CHIP_TOKEN}" \
    https://discord.com/api/v10/channels/${WORKER_POOL_CHANNEL} 2>/dev/null || echo "")

if echo "$CHANNEL" | grep -q "id"; then
    CH_NAME=$(echo "$CHANNEL" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)
    echo "   ✅ Can access channel: #${CH_NAME}"
    
    # Try to send message directly via API
    echo ""
    echo "4. Testing message send via API..."
    
    RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bot ${CHIP_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"content":"🧪 **Debug Test**\nDirect API call successful!"}' \
        https://discord.com/api/v10/channels/${WORKER_POOL_CHANNEL}/messages 2>/dev/null || echo "")
    
    if echo "$RESPONSE" | grep -q "id"; then
        echo "   ✅ Message sent successfully via API!"
        echo "   Check #${CH_NAME} for the message"
    else
        echo "   ❌ Failed to send message"
        echo "   Error: ${RESPONSE}"
        echo ""
        echo "Possible causes:"
        echo "  - Bot lacks 'Send Messages' permission in channel"
        echo "  - Channel permissions are restricted"
        echo ""
        echo "Fix: In Discord, go to #${CH_NAME} → Settings → Permissions"
        echo "     Add your bot and enable 'Send Messages'"
    fi
else
    echo "   ❌ Cannot access channel ${WORKER_POOL_CHANNEL}"
    echo "   Error: ${CHANNEL}"
fi

echo ""
