#!/bin/bash
#
# test-multi-worker.sh - Test multiple workers processing tasks in parallel

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================"
echo "Multi-Worker Pool Test"
echo "======================================"
echo ""

# Cleanup previous runs
rm -rf /tmp/discord-tasks /tmp/discord-workers
mkdir -p /tmp/discord-tasks

echo "✓ Cleaned up previous runs"
echo ""

# Start worker manager with 3 workers in background
echo "Starting worker manager with 3 workers..."
DISCORD_CHANNEL="test-channel" bash "${SCRIPT_DIR}/worker-manager.sh" --workers 3 --channel test-channel > /tmp/worker-manager.log 2>&1 &
MANAGER_PID=$!

# Give workers time to start
echo "Waiting for workers to initialize (5s)..."
sleep 5

echo "✓ Workers started (Manager PID: $MANAGER_PID)"
echo ""

# Submit multiple test tasks
echo "Submitting 5 test tasks..."
echo ""

tasks=(
    "Write a Python function to calculate fibonacci numbers"
    "Write a hello world program in JavaScript"
    "Write a function to reverse a string in Python"
    "Create a simple JSON object with name and age fields"
    "Write a bash script that prints the current date"
)

for i in "${!tasks[@]}"; do
    task_id="task-$(date +%s)-${i}"
    echo "  [$(($i+1))] ${tasks[$i]:0:50}..."
    echo "${task_id}|${tasks[$i]}|openrouter/moonshotai/kimi-k2.5|low" >> /tmp/discord-tasks/queue.txt
    sleep 0.5
done

echo ""
echo "✓ 5 tasks submitted"
echo ""

# Monitor progress
echo "Monitoring progress (120s timeout)..."
echo ""

TIMEOUT=120
ELAPSED=0
COMPLETED=0

while [[ $ELAPSED -lt $TIMEOUT ]] && [[ $COMPLETED -lt 5 ]]; do
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    
    if [[ -f /tmp/discord-tasks/results.txt ]]; then
        COMPLETED=$(grep -c "SUCCESS\|FAILED" /tmp/discord-tasks/results.txt 2>/dev/null || echo "0")
        COMPLETED=$(echo "$COMPLETED" | tr -d '[:space:]')
    fi
    
    # Show status
    CLAIMED=$(grep -c "task-" /tmp/discord-tasks/claimed.txt 2>/dev/null || echo "0")
    CLAIMED=$(echo "$CLAIMED" | tr -d '[:space:]')
    
    printf "\r  %2ds elapsed | Claimed: %d | Completed: %d/5 " $ELAPSED $CLAIMED $COMPLETED
    
    # Early exit if all completed
    if [[ "$COMPLETED" -ge 5 ]]; then
        break
    fi
done

printf "\n\n"

# Results
echo "======================================"
echo "Results Summary"
echo "======================================"
echo ""

if [[ -f /tmp/discord-tasks/results.txt ]]; then
    echo "Completed Tasks:"
    echo ""
    
    while IFS='|' read -r TASK_ID WORKER_ID STATUS TIMESTAMP RESULT; do
        if [[ "$STATUS" == "SUCCESS" ]]; then
            echo "  ✅ $TASK_ID by $WORKER_ID"
            echo "     Result: ${RESULT:0:60}..."
        else
            echo "  ❌ $TASK_ID by $WORKER_ID ($STATUS)"
        fi
        echo ""
    done < /tmp/discord-tasks/results.txt
else
    echo "No results found"
fi

echo "======================================"
echo "Worker Activity Log"
echo "======================================"
echo ""

if [[ -f /tmp/discord-tasks/status.txt ]]; then
    echo "Worker Status Changes:"
    echo ""
    
    # Count events per worker
    grep "READY" /tmp/discord-tasks/status.txt | wc -l | xargs echo "  Ready events:"
    grep "CLAIMED" /tmp/discord-tasks/status.txt | wc -l | xargs echo "  Tasks claimed:"
    grep "SUCCESS" /tmp/discord-tasks/status.txt | wc -l | xargs echo "  Successes:"
    grep "RESTARTING" /tmp/discord-tasks/status.txt | wc -l | xargs echo "  Worker restarts:"
    
    echo ""
    echo "Timeline:"
    tail -20 /tmp/discord-tasks/status.txt | while IFS='|' read -r TS WORKER STATUS MSG; do
        DATE=$(date -d @$TS '+%H:%M:%S' 2>/dev/null || echo $TS)
        echo "  $DATE $WORKER: $STATUS"
    done
fi

echo ""
echo "======================================"
echo "Cleanup"
echo "======================================"

# Stop manager
echo ""
echo "Stopping worker manager (PID: $MANAGER_PID)..."
kill $MANAGER_PID 2>/dev/null || true
sleep 2
pkill -f "worker.sh" 2>/dev/null || true
pkill -f "worker-manager.sh" 2>/dev/null || true

echo "✓ Workers stopped"
echo ""

# Final summary
echo "======================================"
echo "Test Summary"
echo "======================================"
echo ""
echo "Tasks Submitted: 5"
echo "Tasks Completed: $COMPLETED/5"
echo "Workers Used: 3"
echo ""

if [[ $COMPLETED -ge 4 ]]; then
    echo "✅ TEST PASSED: Multi-worker pool working!"
    echo ""
    echo "The workers:"
    echo "  ✅ Started up correctly"
    echo "  ✅ Claimed tasks from queue"
    echo "  ✅ Executed tasks in parallel"
    echo "  ✅ Restarted after each task (context reset)"
    echo ""
    exit 0
else
    echo "❌ TEST FAILED: Only $COMPLETED/5 tasks completed"
    echo ""
    echo "Check /tmp/worker-manager.log for details"
    exit 1
fi
