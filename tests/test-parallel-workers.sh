#!/bin/bash
#
# test-parallel-workers.sh - Test 3 workers processing tasks in parallel
# Verifies no conflicts, proper task distribution, and all complete successfully

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

# Verify we have all tokens
if [[ -z "${WORKER1_TOKEN:-}" || -z "${WORKER2_TOKEN:-}" || -z "${WORKER3_TOKEN:-}" ]]; then
    echo "❌ Missing worker tokens (need WORKER1_TOKEN, WORKER2_TOKEN, WORKER3_TOKEN)"
    exit 1
fi

TEST_DIR="$HOME/Documents/temp"
mkdir -p "$TEST_DIR"
mkdir -p /tmp/discord-tasks

# Clear old results at start
rm -f /tmp/discord-tasks/results.txt 2>/dev/null || true

echo "======================================"
echo "Parallel Workers Test (3 workers)"
echo "======================================"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    kill $WORKER1_PID $WORKER2_PID $WORKER3_PID 2>/dev/null || true
    rm -f "$TEST_DIR"/parallel-test-*.txt 2>/dev/null || true
    rm -rf ~/.openclaw/workspace/worker-parallel-* 2>/dev/null || true
    rm -f /tmp/discord-tasks/results.txt 2>/dev/null || true
}
trap cleanup EXIT

# Create test files
echo "1. Creating 3 test files..."
TEST_FILE_1="$TEST_DIR/parallel-test-1-$(date +%s).txt"
TEST_FILE_2="$TEST_DIR/parallel-test-2-$(date +%s).txt"
TEST_FILE_3="$TEST_DIR/parallel-test-3-$(date +%s).txt"

echo "WORKER_1_FILE" > "$TEST_FILE_1"
echo "WORKER_2_FILE" > "$TEST_FILE_2"
echo "WORKER_3_FILE" > "$TEST_FILE_3"
echo "   ✓ Created test files"
echo ""

# Start 3 workers in parallel
echo "2. Starting 3 workers..."

# Worker 1
ENV_FILE_1="/tmp/worker1-env.sh"
cat > "$ENV_FILE_1" << EOF
export WORKER_ID="parallel-worker-1"
export BOT_TOKEN="${WORKER1_TOKEN}"
export TASK_QUEUE_CHANNEL="${TASK_QUEUE_CHANNEL}"
export RESULTS_CHANNEL="${RESULTS_CHANNEL}"
export WORKER_POOL_CHANNEL="${WORKER_POOL_CHANNEL}"
export POLL_INTERVAL="2"
export MAX_IDLE_TIME="180"
EOF
(
    source "$ENV_FILE_1"
    bash "${SCRIPT_DIR}/../bin/worker-reaction.sh"
) > /tmp/worker1.log 2>&1 &
WORKER1_PID=$!
echo "   ✓ Worker-1 started (PID: $WORKER1_PID)"

# Worker 2
ENV_FILE_2="/tmp/worker2-env.sh"
cat > "$ENV_FILE_2" << EOF
export WORKER_ID="parallel-worker-2"
export BOT_TOKEN="${WORKER2_TOKEN}"
export TASK_QUEUE_CHANNEL="${TASK_QUEUE_CHANNEL}"
export RESULTS_CHANNEL="${RESULTS_CHANNEL}"
export WORKER_POOL_CHANNEL="${WORKER_POOL_CHANNEL}"
export POLL_INTERVAL="2"
export MAX_IDLE_TIME="180"
EOF
(
    source "$ENV_FILE_2"
    bash "${SCRIPT_DIR}/../bin/worker-reaction.sh"
) > /tmp/worker2.log 2>&1 &
WORKER2_PID=$!
echo "   ✓ Worker-2 started (PID: $WORKER2_PID)"

# Worker 3
ENV_FILE_3="/tmp/worker3-env.sh"
cat > "$ENV_FILE_3" << EOF
export WORKER_ID="parallel-worker-3"
export BOT_TOKEN="${WORKER3_TOKEN}"
export TASK_QUEUE_CHANNEL="${TASK_QUEUE_CHANNEL}"
export RESULTS_CHANNEL="${RESULTS_CHANNEL}"
export WORKER_POOL_CHANNEL="${WORKER_POOL_CHANNEL}"
export POLL_INTERVAL="2"
export MAX_IDLE_TIME="180"
EOF
(
    source "$ENV_FILE_3"
    bash "${SCRIPT_DIR}/../bin/worker-reaction.sh"
) > /tmp/worker3.log 2>&1 &
WORKER3_PID=$!
echo "   ✓ Worker-3 started (PID: $WORKER3_PID)"

sleep 3
echo ""

# Submit 3 tasks
echo "3. Submitting 3 tasks..."
TASK_TS=$(date +%s)

"${SCRIPT_DIR}/../bin/submit-to-queue.sh" "Read $TEST_FILE_1, append 'PROCESSED_BY_WORKER_${TASK_TS}_A', report contents"
"${SCRIPT_DIR}/../bin/submit-to-queue.sh" "Read $TEST_FILE_2, append 'PROCESSED_BY_WORKER_${TASK_TS}_B', report contents"
"${SCRIPT_DIR}/../bin/submit-to-queue.sh" "Read $TEST_FILE_3, append 'PROCESSED_BY_WORKER_${TASK_TS}_C', report contents"

echo "   ✓ 3 tasks submitted"
echo ""

# Monitor for completion
echo "4. Monitoring for completion (max 180 seconds)..."
TIMEOUT=180
ELAPSED=0
COMPLETED=0
START_TIME=$(date +%s)

while [[ $ELAPSED -lt $TIMEOUT ]] && [[ $COMPLETED -lt 3 ]]; do
    sleep 3
    ELAPSED=$((ELAPSED + 3))
    
    # Count successful completions from results
    if [[ -f "/tmp/discord-tasks/results.txt" ]]; then
        COMPLETED=$(grep -c "SUCCESS" /tmp/discord-tasks/results.txt 2>/dev/null || echo 0)
    fi
    
    # Show progress
    if [[ $((ELAPSED % 15)) -eq 0 ]]; then
        echo "   ${ELAPSED}s elapsed - $COMPLETED/3 tasks completed"
    fi
done

END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

echo ""
echo "5. Results Summary"
echo "=================="
echo ""
echo "Total time: ${TOTAL_TIME}s"
echo ""

# Analyze results
echo "Completed tasks: $COMPLETED/3"
echo ""

if [[ -f "/tmp/discord-tasks/results.txt" ]]; then
    echo "Results log:"
    grep "SUCCESS\|FAILED" /tmp/discord-tasks/results.txt | tail -5
    echo ""
fi

# Check test files
echo "Test file modifications:"
echo "---"
for i in 1 2 3; do
    FILE_VAR="TEST_FILE_$i"
    FILE_PATH="${!FILE_VAR}"
    if [[ -f "$FILE_PATH" ]]; then
        CONTENT=$(cat "$FILE_PATH")
        if echo "$CONTENT" | grep -q "PROCESSED_BY_WORKER"; then
            echo "File $i: ✅ MODIFIED - $CONTENT"
        else
            echo "File $i: ❌ UNMODIFIED - $CONTENT"
        fi
    else
        echo "File $i: ❌ NOT FOUND"
    fi
done
echo "---"
echo ""

# Worker logs summary
echo "Worker logs (last 10 lines each):"
echo ""
echo "Worker-1:"
tail -10 /tmp/worker1.log 2>/dev/null | sed 's/^/  /' || echo "  No log"
echo ""
echo "Worker-2:"
tail -10 /tmp/worker2.log 2>/dev/null | sed 's/^/  /' || echo "  No log"
echo ""
echo "Worker-3:"
tail -10 /tmp/worker3.log 2>/dev/null | sed 's/^/  /' || echo "  No log"
echo ""

# Final verdict
if [[ $COMPLETED -eq 3 ]]; then
    echo "✅ PARALLEL TEST PASSED - All 3 workers completed their tasks"
    exit 0
else
    echo "❌ PARALLEL TEST FAILED - Only $COMPLETED/3 tasks completed"
    exit 1
fi
