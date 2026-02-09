#!/bin/bash
#
# quick-test.sh - Quick test of the worker pool concept

echo "Discord Worker Pool - Quick Test"
echo "================================"
echo ""

# Setup
rm -rf /tmp/discord-tasks /tmp/discord-workers
mkdir -p /tmp/discord-tasks

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Submit a task
echo "1. Submitting test task..."
echo "task-$(date +%s)|Write a one-sentence hello world program in Python|openrouter/moonshotai/kimi-k2.5|low" >> /tmp/discord-tasks/queue.txt
echo "   ✓ Task added to queue"

# Show queue
echo ""
echo "2. Queue contents:"
cat /tmp/discord-tasks/queue.txt

# Start one worker (this will run the task and exit)
echo ""
echo "3. Starting worker (this will take ~30-60 seconds)..."
WORKER_ID="test-worker-1" DISCORD_CHANNEL="test" timeout 120 bash "${SCRIPT_DIR}/worker.sh"

echo ""
echo "4. Checking results..."

if [[ -f /tmp/discord-tasks/results.txt ]]; then
    echo "   ✓ Results found:"
    cat /tmp/discord-tasks/results.txt
else
    echo "   ✗ No results file"
fi

echo ""
echo "5. Worker status log:"
if [[ -f /tmp/discord-tasks/status.txt ]]; then
    cat /tmp/discord-tasks/status.txt
fi

echo ""
echo "Test complete!"
