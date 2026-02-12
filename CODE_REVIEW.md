# Code Review: discord-orchestration/bin/

## Executive Summary

The discord-orchestration codebase is well-structured and achieves its goal of dynamic agent spawning. However, there are several areas for improvement including potential bugs, missing error handling, and code quality issues.

---

## 1. Potential Bugs & Issues

### 1.1 **CRITICAL: Wrong Token Variable in submit-to-queue.sh**
**File:** `submit-to-queue.sh` (lines 43-48)

```bash
curl -s -X PATCH \
    -H "Authorization: Bot ${CHIP_TOKEN}" \  # BUG: CHIP_TOKEN is undefined
```

**Issue:** The PATCH request uses `${CHIP_TOKEN}` but the script only sources `ORCHESTRATOR_AGENT_TOKEN`. This will cause the message update to fail with 401 Unauthorized.

**Fix:** Change `${CHIP_TOKEN}` to `${ORCHESTRATOR_AGENT_TOKEN}`

---

### 1.2 **Race Condition in orchestrator.sh - Double Assignment Risk**
**File:** `orchestrator.sh` (lines 75-95)

```bash
is_assigned() {
    # ...
    # Race window here: another orchestrator could claim between check and mark
}

# Main loop:
while IFS='|' read -r TASK_ID TASK_CONTENT; do
    is_assigned "$TASK_ID" && continue  # Check 1
    mark_assigned "$TASK_ID"            # Check 2 + claim
```

**Issue:** Between `is_assigned()` and `mark_assigned()`, another orchestrator instance could claim the task. While Discord reactions are atomic, the file-based check introduces a race condition.

**Fix:** Remove the file-based caching and rely solely on Discord's atomic reaction check, or add a file lock mechanism.

---

### 1.3 **Missing File Lock for assigned-tasks.txt**
**File:** `orchestrator.sh` (line 72)

```bash
echo "$TASK_ID" >> "$ASSIGNED_FILE"
```

**Issue:** Concurrent orchestrator instances could corrupt `assigned-tasks.txt` with interleaved writes.

**Fix:** Use `flock` or atomic write operations:
```bash
flock "$ASSIGNED_FILE" -c "echo '$TASK_ID' >> '$ASSIGNED_FILE'"
```

---

### 1.4 **Undefined MAX_RETRIES in Background Subshell**
**File:** `orchestrator.sh` (line 213, 230, 250)

```bash
while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]  # MAX_RETRIES defined in parent
```

**Issue:** While this works due to bash variable inheritance, it's fragile. If the variable name changes or the subshell structure changes, this will fail silently.

**Fix:** Explicitly export or redefine `MAX_RETRIES` at the subshell entry point.

---

### 1.5 **jq Dependency Without Check**
**File:** `orchestrator.sh` (multiple locations)

**Issue:** The script uses `jq` extensively without checking if it's installed. On a fresh system, this causes cryptic errors.

**Fix:** Add at the top:
```bash
command -v jq >/dev/null 2>&1 || { echo "jq is required but not installed." >&2; exit 1; }
```

---

### 1.6 **Hardcoded Timeout Values**
**File:** `orchestrator.sh` (line 201)

```bash
local TIMEOUT=120
if [[ "${THINKING}" == "high" ]]; then
    TIMEOUT=300
fi
```

**Issue:** These timeouts are arbitrary and may not suit all tasks. A long "low" thinking task could timeout unnecessarily.

**Fix:** Allow timeout override via `[timeout:XXX]` tag in task description, similar to model/thinking tags.

---

## 2. Code Quality Improvements

### 2.1 **Inconsistent Error Handling Patterns**

**Current inconsistency:**
```bash
# orchestrator.sh - uses 2>/dev/null
curl ... 2>/dev/null

# submit-to-queue.sh - uses || echo ""
RESPONSE=$(curl ... 2>/dev/null || echo "")

# setup-discord.sh - uses set -e
set -e
```

**Recommendation:** Standardize on one pattern. Consider creating a helper function:
```bash
api_call() {
    local response
    response=$(curl -s -w "\n%{http_code}" "$@" 2>/dev/null)
    local http_code=$(echo "$response" | tail -1)
    local body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        echo "$body"
        return 0
    else
        echo "API Error: HTTP $http_code" >&2
        return 1
    fi
}
```

---

### 2.2 **Code Duplication - Retry Logic**
**File:** `orchestrator.sh` (lines 213-230, 232-248, 250-262)

**Issue:** The retry logic is duplicated three times with slight variations.

**Recommendation:** Extract to a function:
```bash
discord_post_with_retry() {
    local channel="$1"
    local message="$2"
    local max_retries="${3:-5}"
    
    # ... unified retry logic
}
```

---

### 2.3 **Magic Numbers and Strings**

**File:** `orchestrator.sh`

```bash
sleep 0.5  # In clear-task-queue.sh - why 0.5?
sleep 2    # In orchestrator.sh - why 2?
```

**Recommendation:** Use named constants:
```bash
readonly DISCORD_RATE_LIMIT_DELAY=0.5
readonly AGENT_SPAWN_DELAY=2
readonly MAX_DISCORD_RETRIES=5
```

---

### 2.4 **Inconsistent Shebang Options**

**Files:** Various

```bash
#!/bin/bash                    # trigger-orchestrator.sh
#!/bin/bash -                  # clear-task-queue.sh
#!/bin/bash                    # orchestrator.sh with "set -euo pipefail"
```

**Recommendation:** Standardize on `#!/bin/bash` with explicit `set` options in each file for clarity.

---

### 2.5 **Long Functions in orchestrator.sh**

**Issue:** `spawn_agent()` is ~150 lines and does multiple things:
1. Creates workspace
2. Writes config files
3. Posts to Discord
4. Spawns background process
5. Parses session files
6. Calculates costs
7. Posts results
8. Cleans up

**Recommendation:** Split into focused functions:
```bash
spawn_agent() {
    local agent_id=$(create_workspace "$task_id")
    write_agent_config "$agent_id" "$task"
    post_spawn_notice "$agent_id"
    run_agent "$agent_id" &
}

run_agent() {
    execute_task "$@"
    collect_metrics "$@"
    post_results "$@"
    cleanup "$@"
}
```

---

## 3. Missing Error Handling

### 3.1 **No Validation of Discord API Responses**
**File:** `orchestrator.sh` (line 45-46)

```bash
discord_api() {
    # ... returns raw response without validation
    curl -s ... 2>/dev/null
}
```

**Issue:** HTTP errors (401, 403, 429) are silently ignored.

**Fix:** Check HTTP status codes:
```bash
discord_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    
    local response
    response=$(curl -s -w "\n%{http_code}" ...)
    local http_code=$(echo "$response" | tail -1)
    local body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" -ge 400 ]]; then
        echo "Discord API error: HTTP $http_code" >&2
        return 1
    fi
    echo "$body"
}
```

---

### 3.2 **No Disk Space Check**
**File:** `orchestrator.sh` (workspace creation)

**Issue:** The script creates workspaces without checking available disk space. A full disk would cause agent failures.

**Fix:** Add a pre-flight check:
```bash
check_disk_space() {
    local required_mb="${1:-100}"
    local available=$(df -m "$WORKERS_DIR" | awk 'NR==2 {print $4}')
    
    if [[ "$available" -lt "$required_mb" ]]; then
        echo "ERROR: Insufficient disk space. Need ${required_mb}MB, have ${available}MB" >&2
        return 1
    fi
}
```

---

### 3.3 **No Process Limit Check**
**File:** `orchestrator.sh` (agent spawning)

**Issue:** Unlimited parallel agents could exhaust system resources.

**Fix:** Add a semaphore or process limit:
```bash
readonly MAX_PARALLEL_AGENTS=5

spawn_agent() {
    # Wait if too many agents running
    while [[ $(jobs -r | wc -l) -ge $MAX_PARALLEL_AGENTS ]]; do
        sleep 1
    done
    # ... spawn agent
}
```

---

### 3.4 **Missing Validation of Config Loading**
**File:** `orchestrator.sh` (lines 17-21)

```bash
if [[ -f "${REPO_DIR}/discord-config.env" ]]; then
    source "${REPO_DIR}/discord-config.env"
fi
```

**Issue:** If the config is missing, the script continues with empty values, causing cryptic failures later.

**Fix:**
```bash
if [[ -f "${REPO_DIR}/discord-config.env" ]]; then
    source "${REPO_DIR}/discord-config.env"
else
    echo "ERROR: discord-config.env not found. Run setup-discord.sh first." >&2
    exit 1
fi

# Validate required variables
: "${ORCHESTRATOR_AGENT_TOKEN:?ORCHESTRATOR_AGENT_TOKEN is not set}"
: "${TASK_QUEUE_CHANNEL:?TASK_QUEUE_CHANNEL is not set}"
: "${RESULTS_CHANNEL:?RESULTS_CHANNEL is not set}"
```

---

### 3.5 **Silent Failures in Background Jobs**
**File:** `orchestrator.sh` (agent subshell)

**Issue:** If the background agent process crashes, the error is only in `agent-output.log` which may be cleaned up.

**Fix:** Add error trapping and reporting:
```bash
(
    set -euo pipefail
    trap 'echo "Agent failed with exit code $?: $BASH_COMMAND" >> agent-output.log' ERR
    # ... agent logic
)
```

---

## 4. Performance Optimizations

### 4.1 **Python3 Invocation Overhead**
**File:** `orchestrator.sh` (lines 63-72, 135-150, etc.)

**Issue:** Multiple `python3 -c` invocations for JSON parsing add process overhead.

**Fix:** Use `jq` consistently (it's already used elsewhere) or create a single Python helper script:
```bash
# Instead of:
echo "$MESSAGES" | python3 -c "..."

# Use:
echo "$MESSAGES" | jq -r '.[] | select(...)' 2>/dev/null
```

Or create `lib/json-helper.py` for complex operations.

---

### 4.2 **Inefficient Cost Calculation**
**File:** `orchestrator.sh` (lines 234-246)

```bash
# Runs jq 3 times per agent
INPUT_COST=$(jq -r ...)
OUTPUT_COST=$(jq -r ...)
```

**Fix:** Single jq invocation:
```bash
read -r input_cost output_cost < <(jq -r '[...] | @tsv' "$CONFIG_FILE")
```

---

### 4.3 **Session File Scanning**
**File:** `orchestrator.sh` (line 216)

```bash
local SESSION_FILE="${HOME}/.openclaw/agents/main/sessions/${AGENT_ID}-${TASK_ID}.jsonl"
TOKENS_JSON=$(tail -20 "$SESSION_FILE" ...)
```

**Issue:** `tail -20` may miss usage data if the session is long. Also, file I/O for every agent.

**Fix:** Use OpenClaw's API if available, or stream-process the file:
```bash
TOKENS_JSON=$(grep '"usage"' "$SESSION_FILE" | tail -1 | jq '.usage' 2>/dev/null)
```

---

### 4.4 **Sleep-Based Polling**
**File:** `orchestrator.sh` (implied architecture)

**Issue:** The orchestrator is designed to be run via cron every minute, which is inefficient for immediate task processing.

**Recommendation:** Consider adding an optional webhook listener mode:
```bash
# New file: webhook-server.sh
# Use Discord gateway websocket for real-time notifications
# Reduces polling overhead significantly
```

---

### 4.5 **Synchronous Cleanup**
**File:** `orchestrator.sh` (line 258)

```bash
rm -rf "$WORKER_STATE_DIR"
```

**Issue:** Cleanup happens synchronously. Large workspaces with many files could block.

**Fix:** Background the cleanup:
```bash
(rm -rf "$WORKER_STATE_DIR" 2>/dev/null &)  
```

Or use a dedicated cleanup job that runs periodically.

---

## 5. Security Concerns

### 5.1 **Token Logging Risk**
**File:** `orchestrator.sh` (agent subshell)

```bash
export BOT_TOKEN="${BOT_TOKEN}"  # Exported to subshell
```

**Issue:** If `agent-output.log` captures environment or the agent dumps its env, tokens could leak.

**Fix:** 
1. Don't export tokens to agent subshells
2. Use file-based token passing with restricted permissions
3. Clear sensitive variables from logs

---

### 5.2 **Path Traversal Risk**
**File:** `orchestrator.sh` (line 104)

```bash
mkdir -p "$TASK_DIR"
```

**Issue:** If `TASK_ID` contains `../` or other path components, it could write outside the intended directory.

**Fix:** Sanitize task IDs:
```bash
TASK_ID=$(echo "$TASK_ID" | tr -cd 'a-zA-Z0-9_-')
```

---

### 5.3 **World-Readable Log Files**
**File:** `orchestrator.sh` (implicit)

**Issue:** `agent-output.log` may contain sensitive information and is created with default permissions.

**Fix:** Set restrictive umask:
```bash
umask 077  # Owner-only access
```

---

## 6. Recommendations Summary

### High Priority (Fix Immediately)
1. **Fix CHIP_TOKEN bug** in `submit-to-queue.sh`
2. **Add file locking** for `assigned-tasks.txt`
3. **Add jq dependency check**
4. **Validate required config variables**

### Medium Priority (Improve Soon)
1. Extract retry logic to shared function
2. Add disk space and process limits
3. Standardize error handling patterns
4. Add input validation (path sanitization)

### Low Priority (Nice to Have)
1. Add webhook/listener mode for real-time processing
2. Create shared library for common functions
3. Add metrics/monitoring hooks
4. Write unit tests using `bats` or similar

---

## Appendix: Suggested Shared Library

Create `lib/common.sh`:

```bash
#!/bin/bash
# Common functions for discord-orchestration

set -euo pipefail

# Logging
log_info() { echo "[$(date '+%H:%M:%S')] INFO: $*" >&2; }
log_error() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; }

# Config validation
validate_config() {
    local required_vars=("$@")
    for var in "${required_vars[@]}"; do
        : "${!var:?${var} is not set}"
    done
}

# Discord API with retry
discord_api_retry() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local max_retries="${4:-5}"
    
    local attempt=0
    while [[ $attempt -lt $max_retries ]]; do
        local response
        response=$(curl -s -w "\n%{http_code}" ...)
        local http_code=$(echo "$response" | tail -1)
        
        if [[ "$http_code" =~ ^2 ]]; then
            echo "$response" | sed '$d'
            return 0
        fi
        
        attempt=$((attempt + 1))
        sleep $((2 ** attempt))
    done
    
    return 1
}

# Cleanup
 cleanup_workspace() {
    local dir="$1"
    [[ -d "$dir" ]] && rm -rf "$dir" &
}
```

Then source in all scripts:
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
```

---

*Review Date: 2026-02-11*
*Reviewer: Code Review Agent*
*Scope: bin/ directory only*
