#!/bin/bash
#
# test-discord-worker.sh - Test a single Discord worker with curl

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config
if [[ -f "${SCRIPT_DIR}/discord-config.env" ]]; then
    source "${SCRIPT_DIR}/discord-config.env"
fi

echo "======================================"
echo "Discord Worker Test (curl)"
echo "======================================"
echo ""

# Check config
if [[ -z "$WORKER1_TOKEN" ]]; then
    echo "❌ WORKER1_TOKEN not set"
    echo "Run ./setup-discord.sh first"
    exit 1
fi

# Setup
rm -rf /tmp/discord-tasks /tmp/discord-workers
mkdir -p /tmp/discord-tasks

echo "✓ Cleaned up previous runs"
echo ""

# Submit a test task
echo "Submitting test task..."
task_id="test-discord-$(date +%s)"
echo "${task_id}|Write a hello world program in Python|openrouter/moonshotai/kimi-k2.5|low" > /tmp/discord-tasks/queue.txt
echo "✓ Task added: ${task_id}"
echo ""

# Run worker
echo "Starting worker-1 (will execute task and post to Discord)..."
echo ""

export WORKER_ID="worker-1"
export BOT_TOKEN="$WORKER1_TOKEN"
export RESULTS_CHANNEL="${RESULTS_CHANNEL:-}"
export WORKER_POOL_CHANNEL="${WORKER_POOL_CHANNEL:-}"
export POLL_INTERVAL="2"
export MAX_IDLE_TIME="60"

timeout 90 bash "${SCRIPT_DIR}/worker-discord-curl.sh" 2>&1 | tee /tmp/discord-worker-test.log

echo ""
echo "======================================"
echo "Results"
echo "======================================"
echo ""

if [[ -f /tmp/discord-tasks/results.txt ]]; then
    echo "Local Results:"
    cat /tmp/discord-tasks/results.txt
    echo ""
    echo "✅ Task completed!"
    echo ""
    echo "Check Discord channels:"
    echo "  - #worker-pool for READY/CLAIMED/RESTARTING messages"
    echo "  - #results for the task result"
else
    echo "❌ No results found"
    echo "Check /tmp/discord-worker-test.log for errors"
fi

echo ""
