#!/bin/bash
#
# spawn-worker.sh (Phase 0: File-Based Coordination)
# Simple standalone worker spawner for testing
#
# Usage: ./spawn-worker.sh --task-id <uuid> --task "description"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_BASE="${HOME}/.openclaw/discord-workers"
OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

# Parse args
TASK_ID="${2:-}"
TASK_DESCRIPTION=""
MODEL="openrouter/moonshotai/kimi-k2.5"
THINKING="low"
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task-id) TASK_ID="$2"; shift 2 ;;
        --task) TASK_DESCRIPTION="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --thinking) THINKING="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[[ -z "${TASK_ID}" ]] && { log "ERROR: --task-id required"; exit 1; }
[[ -z "${TASK_DESCRIPTION}" ]] && { log "ERROR: --task required"; exit 1; }
OUTPUT_DIR="${OUTPUT_DIR:-${WORKSPACE_BASE}/${TASK_ID}}"

log "=== Spawning Worker: ${TASK_ID} ==="

# Setup workspace
rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}/workspace"

# Create task files
cat > "${OUTPUT_DIR}/workspace/TASK.txt" << EOF
${TASK_DESCRIPTION}

When done, write your result to: ${OUTPUT_DIR}/workspace/RESULT.txt
Then write "DONE" to: ${OUTPUT_DIR}/COMPLETED
EOF

cat > "${OUTPUT_DIR}/workspace/AGENTS.md" << EOF
# Worker - Task ${TASK_ID}

Complete the task in TASK.txt.
Write result to RESULT.txt.
Write "DONE" to ${OUTPUT_DIR}/COMPLETED when finished.
EOF

# Create run script
RUN_SCRIPT="${OUTPUT_DIR}/run.sh"
cat > "$RUN_SCRIPT" << 'INNERSCRIPT'
#!/bin/bash
set -e
TASK_DIR="$1"
MODEL="$2"
THINKING="$3"

cd "$TASK_DIR/workspace"

# Copy to OpenClaw workspace
cp AGENTS.md TASK.txt "$HOME/.openclaw/workspace/" 2>/dev/null || true

# Run agent locally with task
openclaw agent --local \
    --message "Complete the task described in TASK.txt. Write result to RESULT.txt. Then write DONE to ../COMPLETED." \
    --thinking "$THINKING" \
    --json > ../agent-output.json 2>&1 || true

# Signal completion
echo "DONE" > ../COMPLETED
INNERSCRIPT

chmod +x "$RUN_SCRIPT"

log "Starting worker..."

# Run worker in foreground for testing
bash "$RUN_SCRIPT" "$OUTPUT_DIR" "$MODEL" "$THINKING"

# Wait for completion signal
TIMEOUT=300
ELAPSED=0
while [[ ! -f "${OUTPUT_DIR}/COMPLETED" ]] && [[ $ELAPSED -lt $TIMEOUT ]]; do
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if [[ -f "${OUTPUT_DIR}/COMPLETED" ]]; then
    log "Worker completed!"
    
    RESULT=""
    [[ -f "${OUTPUT_DIR}/workspace/RESULT.txt" ]] && RESULT=$(cat "${OUTPUT_DIR}/workspace/RESULT.txt")
    
    cat > "${OUTPUT_DIR}/result.json" << EOF
{
    "task_id": "${TASK_ID}",
    "status": "success",
    "result": "${RESULT}",
    "workspace": "${OUTPUT_DIR}/workspace"
}
EOF
    log "Result: ${RESULT:0:100}..."
    exit 0
else
    log "Worker timed out"
    cat > "${OUTPUT_DIR}/result.json" << EOF
{
    "task_id": "${TASK_ID}",
    "status": "timeout",
    "workspace": "${OUTPUT_DIR}/workspace"
}
EOF
    exit 3
fi
