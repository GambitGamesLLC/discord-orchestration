#!/bin/bash
#
# test-filesystem-access.sh - Verify workers can read/write outside sandbox
# This test confirms gateway-attached workers have full filesystem access

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config
if [[ -f "${SCRIPT_DIR}/../discord-config.env" ]]; then
    source "${SCRIPT_DIR}/../discord-config.env"
elif [[ -f "${SCRIPT_DIR}/discord-config.env" ]]; then
    source "${SCRIPT_DIR}/discord-config.env"
else
    echo "❌ discord-config.env not found"
    exit 1
fi

TEST_DIR="$HOME/Documents/temp"
TEST_FILE="$TEST_DIR/worker-fs-test-$(date +%s).txt"

echo "======================================"
echo "Filesystem Access Test"
echo "======================================"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    kill $WORKER_PID 2>/dev/null || true
    rm -f "$TEST_FILE" 2>/dev/null || true
    rm -rf "$HOME/.openclaw/workspace/worker-test-fs-*" 2>/dev/null || true
}
trap cleanup EXIT

# Step 1: Create test file outside sandbox
echo "1. Creating test file at: $TEST_FILE"
mkdir -p "$TEST_DIR"
echo "INITIAL_CONTENT_12345" > "$TEST_FILE"
echo "   ✓ Created with content: $(cat "$TEST_FILE")"
echo ""

# Step 2: Start worker (with --local removed for full filesystem access)
echo "2. Starting gateway-attached worker (non-sandboxed)..."
ENV_FILE="/tmp/worker-fs-test-env.sh"
cat > "$ENV_FILE" << EOF
export WORKER_ID="test-fs-worker"
export BOT_TOKEN="${WORKER1_TOKEN}"
export TASK_QUEUE_CHANNEL="${TASK_QUEUE_CHANNEL}"
export RESULTS_CHANNEL="${RESULTS_CHANNEL}"
export WORKER_POOL_CHANNEL="${WORKER_POOL_CHANNEL}"
export POLL_INTERVAL="3"
export MAX_IDLE_TIME="120"
EOF

(
    source "$ENV_FILE"
    bash "${SCRIPT_DIR}/../bin/worker-reaction.sh"
) > /tmp/worker-fs-test.log 2>&1 &
WORKER_PID=$!

sleep 3
echo "   ✓ Worker started (PID: $WORKER_PID)"
echo ""

# Step 3: Submit task that reads AND writes to ~/Documents/temp/
echo "3. Submitting filesystem access test task..."
TASK_DESC="Read the file at $TEST_FILE and append a new line that says 'WORKER_WAS_HERE_$(date +%s)'. Then read the file again and report its full contents."

"${SCRIPT_DIR}/../bin/submit-to-queue.sh" "$TASK_DESC"
echo "   ✓ Task submitted"
echo ""

# Step 4: Monitor for completion
echo "4. Monitoring for 90 seconds..."
TIMEOUT=90
ELAPSED=0
COMPLETED=0

while [[ $ELAPSED -lt $TIMEOUT ]] && [[ $COMPLETED -lt 1 ]]; do
    sleep 3
    ELAPSED=$((ELAPSED + 3))
    
    if [[ -f "/tmp/discord-tasks/results.txt" ]]; then
        COMPLETED=$(grep -c "SUCCESS\|FAILED" /tmp/discord-tasks/results.txt 2>/dev/null || echo 0)
    fi
    
    echo -ne "   Waiting... ${ELAPSED}s elapsed\r"
done
echo ""
echo ""

# Step 5: Verify results
echo "5. Verifying filesystem access..."
echo ""

# Check if worker reported success
if [[ -f "/tmp/discord-tasks/results.txt" ]]; then
    LATEST_RESULT=$(tail -1 /tmp/discord-tasks/results.txt)
    echo "   Worker result: $LATEST_RESULT"
    echo ""
fi

# Check if the test file was modified by the worker
echo "   Checking test file: $TEST_FILE"
if [[ -f "$TEST_FILE" ]]; then
    FILE_CONTENT=$(cat "$TEST_FILE")
    echo "   File contents:"
    echo "   ---"
    echo "   $FILE_CONTENT"
    echo "   ---"
    echo ""
    
    if echo "$FILE_CONTENT" | grep -q "WORKER_WAS_HERE"; then
        echo "   ✅ SUCCESS! Worker successfully wrote to file outside sandbox"
        echo ""
        echo "   ✅ Filesystem access test PASSED"
        echo ""
        echo "   The worker demonstrated:"
        echo "   - Read access to ~/Documents/temp/"
        echo "   - Write access to ~/Documents/temp/"
        echo ""
        exit 0
    else
        echo "   ⚠️  Worker did not write expected content to file"
        echo "   The file may have been read but not modified as expected"
    fi
else
    echo "   ❌ Test file not found!"
fi

echo ""
echo "   Worker log (last 30 lines):"
tail -30 /tmp/worker-fs-test.log 2>/dev/null || echo "   No log available"

echo ""
echo "   ❌ Filesystem access test FAILED"
exit 1
