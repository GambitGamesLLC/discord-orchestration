#!/bin/bash
#
# setup-discord.sh - Configure Discord bot tokens and channel IDs

set -e

echo "======================================"
echo "Discord Orchestration Setup"
echo "======================================"
echo ""
echo "This script will help you configure the Discord integration."
echo "You'll need the bot tokens from Discord Developer Portal."
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/discord-config.env"

# Check if config already exists
if [[ -f "$CONFIG_FILE" ]]; then
    echo "Config file already exists: $CONFIG_FILE"
    read -p "Overwrite? (y/N): " OVERWRITE
    if [[ "$OVERWRITE" != "y" && "$OVERWRITE" != "Y" ]]; then
        echo "Setup cancelled."
        exit 0
    fi
fi

echo ""
echo "--- Bot Tokens ---"
echo "Get these from: https://discord.com/developers/applications"
echo "(Bot → Reset Token or Copy)"
echo ""

read -p "Chip (Orchestrator) Bot Token: " CHIP_TOKEN
read -p "Worker-1 Bot Token: " WORKER1_TOKEN
read -p "Worker-2 Bot Token: " WORKER2_TOKEN
read -p "Worker-3 Bot Token: " WORKER3_TOKEN

echo ""
echo "--- Discord Channel IDs ---"
echo "Right-click channel → 'Copy Channel ID' (need Developer Mode on)"
echo ""

read -p "Task Queue Channel ID: " TASK_QUEUE_CHANNEL
read -p "Results Channel ID: " RESULTS_CHANNEL
read -p "Worker Pool Channel ID: " WORKER_POOL_CHANNEL
read -p "Orchestrator Commands Channel ID: " ORCHESTRATOR_CHANNEL

echo ""
echo "--- Guild/Server ID ---"
echo "Right-click server name → 'Copy Server ID'"
echo ""

read -p "Discord Server/Guild ID: " GUILD_ID

# Create config file
cat > "$CONFIG_FILE" << EOF
# Discord Orchestration Configuration
# Generated: $(date)

# Bot Tokens (KEEP SECRET!)
CHIP_TOKEN="${CHIP_TOKEN}"
WORKER1_TOKEN="${WORKER1_TOKEN}"
WORKER2_TOKEN="${WORKER2_TOKEN}"
WORKER3_TOKEN="${WORKER3_TOKEN}"

# Channel IDs
TASK_QUEUE_CHANNEL="${TASK_QUEUE_CHANNEL}"
RESULTS_CHANNEL="${RESULTS_CHANNEL}"
WORKER_POOL_CHANNEL="${WORKER_POOL_CHANNEL}"
ORCHESTRATOR_CHANNEL="${ORCHESTRATOR_CHANNEL}"

# Server ID
GUILD_ID="${GUILD_ID}"
EOF

chmod 600 "$CONFIG_FILE"

echo ""
echo "======================================"
echo "✓ Configuration saved to:"
echo "  $CONFIG_FILE"
echo ""
echo "Permissions set to 600 (owner read/write only)"
echo ""
echo "To use these settings, run:"
echo "  source $CONFIG_FILE"
echo ""
echo "Or in your scripts:"
echo "  source ./discord-config.env"
echo "======================================"
