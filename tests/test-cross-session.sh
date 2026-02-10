#!/bin/bash
#
# test-cross-session-communication.sh - Test workers coordinating via shared files
# Worker A writes intermediate data, Worker B reads and completes

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../discord-config.env"

TEST_DIR="$HOME/Documents/temp"
mkdir -p "$TEST_DIR"
SHARED_FILE="$TEST_DIR/cross-session-data-$(date +%s).json"

echo "======================================"
echo "Cross-Session Communication Test"
echo "======================================"
echo ""

# Cleanup
rm -f /tmp/discord-tasks/results.txt 2>/dev/null || true

cleanup() {
    echo ""
    echo "Cleaning up..."
    kill $WORKER1_PID $WORKER2_PID 2>/dev/null || true
    rm -f "$SHARED_FILE" 2>/dev/null || true
    rm -rf ~/.openclaw/workspace/worker-cross-* 2>/dev/null || true
}
trap cleanup EXIT

# Start 2 workers
echo "1. Starting 2 workers..."

for i in 1 2; do
    TOKEN_VAR="WORKER${i}_TOKEN"
    cat > "/tmp/cross-worker${i}-env.sh" << EOF
export WORKER_ID="cross-worker-${i}"
export BOT_TOKEN="${!TOKEN_VAR}"
export TASK_QUEUE_CHANNEL="${TASK_QUEUE_CHANNEL}"
export RESULTS_CHANNEL="${RESULTS_CHANNEL}"
export WORKER_POOL_CHANNEL="${WORKER_POOL_CHANNEL}"
export POLL_INTERVAL="2"
export MAX_IDLE_TIME="300"
EOF
    (
        source "/tmp/cross-worker${i}-env.sh"
        bash "${SCRIPT_DIR}/../bin/worker-reaction.sh"
    ) > "/tmp/cross-worker${i}.log" 2>&1 &
    eval "WORKER${i}_PID=$!"
    echo "   ✓ Worker-$i started (PID: $(eval echo \$WORKER${i}_PID))"
done

sleep 3
echo ""

# Submit Task 1: Generate and save data
echo "2. Submitting Task 1 (data generation)..."
"${SCRIPT_DIR}/../bin/submit-to-queue.sh" "Generate a JSON object with 3 key-value pairs (name, timestamp, random_number) and save it to $SHARED_FILE. Report what you saved."

echo "   Waiting for Task 1 completion (max 60s)..."
for i in $(seq 1 20); do
    sleep 3
    if [[ -f "$SHARED_FILE" ]]; then
        echo "   ✓ Shared file created at ${i}*3=$(((i*3)))s"
        break
    fi
done

if [[ ! -f "$SHARED_FILE" ]]; then
    echo "   ❌ Task 1 failed - no shared file created"
    exit 1
fi

echo ""
echo "   Shared file contents:"
cat "$SHARED_FILE" | head -10 | sed 's/^/   /'
echo ""

# Submit Task 2: Read and process the data
echo "3. Submitting Task 2 (data processing)..."
"${SCRIPT_DIR}/../bin/submit-to-queue.sh" "Read the JSON file at $SHARED_FILE, add a 'processed_by' field with your worker ID, and save it back. Report the final contents."

echo "   Waiting for Task 2 completion (max 60s)..."
for i in $(seq 1 20); do
    sleep 3
    if grep -q "processed_by" "$SHARED_FILE" 2>/dev/null; then
        echo "   ✓ File processed at ${i}*3=$(((i*3)))s"
        break
    fi
done

echo ""
echo "4. Results"
echo "=========="
echo ""

echo "Final shared file contents:"
cat "$SHARED_FILE" | sed 's/^/   /'
echo ""

# Check if cross-session communication worked
if grep -q "processed_by" "$SHARED_FILE" 2>/dev/null; then
    echo "✅ CROSS-SESSION TEST PASSED"
    echo "   - Worker A created shared file"
    echo "   - Worker B read, modified, and saved it back"
    echo "   - Coordination via filesystem successful"
    exit 0
else
    echo "❌ CROSS-SESSION TEST FAILED"
    echo "   - File was not processed by second worker"
    exit 1
fi
