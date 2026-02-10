#!/bin/bash
#
# test-first-reactor-wins.sh - Simple test of first-reactor-wins logic

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../discord-config.env"

TEST_DIR="$HOME/Documents/temp"
mkdir -p "$TEST_DIR"

echo "======================================"
echo "First-Reactor-Wins Test"
echo "======================================"
echo ""

# Cleanup old test files
rm -f "$TEST_DIR"/frw-test-*.txt 2>/dev/null || true

# Create test file
TEST_FILE="$TEST_DIR/frw-test-$(date +%s).txt"
echo "INITIAL_DATA" > "$TEST_FILE"
echo "1. Created test file: $TEST_FILE"
echo "   Content: $(cat "$TEST_FILE")"
echo ""

# Start 3 workers
echo "2. Starting 3 workers..."

for i in 1 2 3; do
    TOKEN_VAR="WORKER${i}_TOKEN"
    cat > "/tmp/frw-worker${i}-env.sh" << EOF
export WORKER_ID="frw-worker-${i}"
export BOT_TOKEN="${!TOKEN_VAR}"
export TASK_QUEUE_CHANNEL="${TASK_QUEUE_CHANNEL}"
export RESULTS_CHANNEL="${RESULTS_CHANNEL}"
export WORKER_POOL_CHANNEL="${WORKER_POOL_CHANNEL}"
export POLL_INTERVAL="2"
export MAX_IDLE_TIME="300"
EOF
    (
        source "/tmp/frw-worker${i}-env.sh"
        bash "${SCRIPT_DIR}/../bin/worker-reaction.sh"
    ) > "/tmp/frw-worker${i}.log" 2>&1 &
    eval "WORKER${i}_PID=$!"
    echo "   ✓ Worker-$i started (PID: $(eval echo \$WORKER${i}_PID))"
done

sleep 3
echo ""

# Submit task
echo "3. Submitting task..."
"${SCRIPT_DIR}/../bin/submit-to-queue.sh" "Read $TEST_FILE, append 'CLAIMED_BY_WORKER_$(date +%s)', report contents"
echo ""

# Wait for completion
echo "4. Waiting for task completion (max 120s)..."
for i in $(seq 1 40); do
    sleep 3
    
    # Check if file was modified
    if grep -q "CLAIMED_BY_WORKER" "$TEST_FILE" 2>/dev/null; then
        echo "   ✓ File modified at ${i}*3=${$((i*3))}s"
        break
    fi
done

echo ""
echo "5. Results"
echo "=========="
echo ""

# Show file content
echo "Test file content:"
cat "$TEST_FILE"
echo ""

# Check Discord results
echo "Discord results (last 3):"
curl -s -X GET -H "Authorization: Bot ${WORKER1_TOKEN}" "https://discord.com/api/v10/channels/${RESULTS_CHANNEL}/messages?limit=5" 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for m in data[:3]:
        ts = m['timestamp'][:19] if 'timestamp' in m else 'unknown'
        author = m['author']['username'] if 'author' in m else 'unknown'
        content = m['content'][:80] if 'content' in m else 'no content'
        print(f\"  [{ts}] {author}: {content}...\")
except Exception as e:
    print(f'  Error: {e}')
"

echo ""
echo "Worker logs (relevant lines):"
for i in 1 2 3; do
    echo "Worker-$i:"
    grep -E "CLAIMED|Lost race|first:" "/tmp/frw-worker${i}.log" 2>/dev/null | sed 's/^/  /' || echo "  (no relevant log entries)"
done

echo ""

# Cleanup
kill $WORKER1_PID $WORKER2_PID $WORKER3_PID 2>/dev/null || true
rm -f "$TEST_FILE" "/tmp/frw-worker"*.log "/tmp/frw-worker"*-env.sh 2>/dev/null || true

if grep -q "CLAIMED_BY_WORKER" "$TEST_FILE" 2>/dev/null; then
    echo "✅ Test completed - file was modified by a worker"
else
    echo "❌ Test failed - file was not modified"
fi
