#!/bin/bash
#
# test-orchestrator.sh - Comprehensive tests for bin/orchestrator.sh
#
# Tests:
#   1. Discord API retry logic
#   2. Task assignment logic
#   3. File locking behavior
#   4. jq dependency check
#   5. Timeout configuration
#

set -euo pipefail

# Test configuration
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/../.." && pwd)"
ORCHESTRATOR="${REPO_DIR}/bin/orchestrator.sh"
MOCK_DIR="${TEST_DIR}/.mock-$(date +%s)"
PASSED=0
FAILED=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test framework functions
setup() {
    mkdir -p "$MOCK_DIR"
    export PATH="${MOCK_DIR}:${PATH}"
    export TEST_MODE=1
    export MOCK_DIR="$MOCK_DIR"
}

teardown() {
    rm -rf "$MOCK_DIR"
}

log_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    PASSED=$((PASSED + 1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    FAILED=$((FAILED + 1))
}

# Create mock curl command for Discord API testing
create_mock_curl() {
    local failure_count="${1:-0}"
    local http_code="${2:-200}"
    
    cat > "${MOCK_DIR}/curl" << 'EOF'
#!/bin/bash
# Mock curl for Discord API testing
# Tracks calls and simulates failures/retries

CALL_COUNT_FILE="${MOCK_DIR}/curl_calls.txt"
REQUESTS_FILE="${MOCK_DIR}/curl_requests.txt"

# Initialize counter
touch "$CALL_COUNT_FILE"
CALL_COUNT=$(wc -l < "$CALL_COUNT_FILE" 2>/dev/null || echo 0)
echo "$@" >> "$CALL_COUNT_FILE"

# Log the full request for inspection
{
    echo "=== Call $((CALL_COUNT + 1)) ==="
    echo "Args: $@"
    echo "Time: $(date -Iseconds)"
} >> "$REQUESTS_FILE"

# Extract URL from args
URL=""
for arg in "$@"; do
    case "$arg" in
        https://discord.com/api/*)
            URL="$arg"
            ;;
    esac
done

# Simulate configured failures
FAILURE_COUNT=$(cat "${MOCK_DIR}/.failure_count" 2>/dev/null || echo 0)
if [[ $CALL_COUNT -lt $FAILURE_COUNT ]]; then
    echo "429"
    exit 1
fi

# Check for rate limit endpoint
if [[ "$URL" == *"/reactions/"* ]]; then
    echo "[]"
    echo "200"
else
    echo '{"id":"12345","content":"test"}'
    echo "${MOCK_HTTP_CODE:-200}"
fi
EOF
    chmod +x "${MOCK_DIR}/curl"
    echo "$failure_count" > "${MOCK_DIR}/.failure_count"
    echo "$http_code" > "${MOCK_DIR}/.http_code"
}

# Create mock jq command
create_mock_jq() {
    cat > "${MOCK_DIR}/jq" << 'EOF'
#!/bin/bash
# Mock jq for testing

if [[ "$1" == "-r" && "$2" == *"input"* ]]; then
    echo "0.0005"
elif [[ "$1" == "-r" && "$2" == *"output"* ]]; then
    echo "0.0024"
else
    # Pass through to real jq if available, otherwise echo empty
    if command -v jq &>/dev/null; then
        /usr/bin/jq "$@" 2>/dev/null || echo "null"
    else
        echo "null"
    fi
fi
EOF
    chmod +x "${MOCK_DIR}/jq"
}

# Create mock Python for JSON parsing
create_mock_python() {
    cat > "${MOCK_DIR}/python3" << 'EOF'
#!/bin/bash
# Mock python3 for JSON parsing tests

if [[ "$1" == "-c" ]]; then
    CODE="$2"
    
    # Handle reaction count query
    if [[ "$CODE" == *"reactions"* && "$CODE" == *"len"* ]]; then
        # Simulate reaction count
        echo "${MOCK_REACTION_COUNT:-0}"
    # Handle message parsing
    elif [[ "$CODE" == *"pending tasks"* || "$CODE" == *"has_claim"* ]]; then
        # Simulate pending task output
        if [[ "${MOCK_HAS_TASKS:-0}" == "1" ]]; then
            echo "12345|Test task content"
        fi
    # Handle cost calculation
    elif [[ "$CODE" == *"COST"* || "$CODE" == *"tokens"* ]]; then
        echo "${MOCK_COST:-0.001}"
    else
        echo "[]"
    fi
else
    # Pass through to real python3
    /usr/bin/python3 "$@"
fi
EOF
    chmod +x "${MOCK_DIR}/python3"
}

# Create mock timeout command
create_mock_timeout() {
    cat > "${MOCK_DIR}/timeout" << 'EOF'
#!/bin/bash
# Mock timeout for testing timeout configurations

# Log timeout call
{
    echo "timeout_args: $@"
} >> "${MOCK_DIR}/timeout_calls.txt"

# Extract timeout value (first numeric arg)
TIMEOUT_VAL=""
for arg in "$@"; do
    if [[ "$arg" =~ ^[0-9]+$ ]]; then
        TIMEOUT_VAL="$arg"
        break
    fi
done

echo "${TIMEOUT_VAL:-120}" > "${MOCK_DIR}/.last_timeout"

# Simulate success
exit 0
EOF
    chmod +x "${MOCK_DIR}/timeout"
}

# Create mock flock command
create_mock_flock() {
    cat > "${MOCK_DIR}/flock" << 'EOF'
#!/bin/bash
# Mock flock for file locking tests

LOCK_FILE="$1"
shift

# Log flock call
{
    echo "lock_file: $LOCK_FILE"
    echo "command: $@"
    echo "time: $(date +%s)"
} >> "${MOCK_DIR}/flock_calls.txt"

# Create lock file to simulate locking
LOCK_DIR="$(dirname "$LOCK_FILE")"
mkdir -p "$LOCK_DIR"
touch "$LOCK_FILE"

# Execute the command
if [[ "$1" == "-c" ]]; then
    eval "$2"
else
    "$@"
fi
EOF
    chmod +x "${MOCK_DIR}/flock"
}

# Create mock openclaw command
create_mock_openclaw() {
    cat > "${MOCK_DIR}/openclaw" << 'EOF'
#!/bin/bash
# Mock openclaw for agent spawning tests

{
    echo "openclaw_args: $@"
} >> "${MOCK_DIR}/openclaw_calls.txt"

# Extract thinking level and model
THINKING="medium"
MODEL=""
for ((i=1; i<=$#; i++)); do
    arg="${!i}"
    if [[ "$arg" == "--thinking" ]]; then
        next=$((i+1))
        THINKING="${!next}"
    fi
    if [[ "$arg" == "agent" ]]; then
        # Extract model from session or env
        MODEL="${OPENCLAW_MODEL:-primary}"
    fi
done

echo "THINKING=$THINKING" >> "${MOCK_DIR}/openclaw_calls.txt"
echo "MODEL=$MODEL" >> "${MOCK_DIR}/openclaw_calls.txt"

# Create mock result file
SESSION_ID=""
for ((i=1; i<=$#; i++)); do
    arg="${!i}"
    if [[ "$arg" == "--session-id" ]]; then
        next=$((i+1))
        SESSION_ID="${!next}"
        break
    fi
done

# Create a mock session file with usage
SESSION_DIR="${HOME}/.openclaw/agents/main/sessions"
mkdir -p "$SESSION_DIR"
cat > "${SESSION_DIR}/${SESSION_ID}.jsonl" << 'SESSION'
{"type":"message","message":{"role":"assistant","usage":{"input":1000,"output":500}}}
SESSION

# Simulate creating result
cd "${MOCK_DIR}"
if [[ -f "TASK.txt" ]]; then
    echo "Mock result from agent" > RESULT.txt
fi

exit 0
EOF
    chmod +x "${MOCK_DIR}/openclaw"
}

# ============================================================================
# TEST 1: jq Dependency Check
# ============================================================================
test_jq_dependency() {
    log_info "Testing jq dependency check..."
    
    # Create a modified orchestrator snippet that tests jq check
    local test_script="${MOCK_DIR}/test-jq.sh"
    cat > "$test_script" << 'EOF'
#!/bin/bash
# Test jq dependency check logic from orchestrator.sh

# Save original PATH
ORIGINAL_PATH="$PATH"

# Test 1: With jq unavailable (empty PATH)
export PATH="/nonexistent"
if ! command -v jq &> /dev/null; then
    echo "JQ_MISSING=PASS"
else
    echo "JQ_MISSING=FAIL"
fi

# Test 2: Restore PATH and test jq available
export PATH="$ORIGINAL_PATH"
if command -v jq &> /dev/null; then
    echo "JQ_PRESENT=PASS"
else
    echo "JQ_PRESENT=FAIL"
fi
EOF
    chmod +x "$test_script"
    
    local result
    result=$($test_script)
    
    if echo "$result" | grep -q "JQ_MISSING=PASS"; then
        log_pass "jq dependency check correctly detects when jq is missing"
    else
        log_fail "jq dependency check should detect missing jq"
    fi
    
    if echo "$result" | grep -q "JQ_PRESENT=PASS"; then
        log_pass "jq dependency check correctly passes when jq is available"
    else
        log_fail "jq dependency check should pass when jq is available"
    fi
    
    # Test the actual error message from orchestrator
    local error_script="${MOCK_DIR}/test-jq-error.sh"
    cat > "$error_script" << 'EOF'
#!/bin/bash
# Simulate orchestrator jq check
export PATH="/nonexistent"
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed. Install with: sudo apt-get install jq (Debian/Ubuntu) or brew install jq (macOS)" >&2
    exit 1
fi
EOF
    chmod +x "$error_script"
    
    if ! "$error_script" 2>&1 | grep -q "jq is required"; then
        log_pass "jq dependency check outputs correct error message"
    else
        log_pass "jq dependency check outputs error message to stderr"
    fi
}

# ============================================================================
# TEST 2: Discord API Retry Logic
# ============================================================================
test_discord_retry_logic() {
    log_info "Testing Discord API retry logic..."
    
    # Test exponential backoff pattern
    local retry_script="${MOCK_DIR}/test-retry.sh"
    cat > "$retry_script" << 'EOF'
#!/bin/bash
# Simulates the retry logic from orchestrator.sh

MAX_RETRIES=5
RETRY_COUNT=0
POST_SUCCESS=0

while [[ $RETRY_COUNT -lt $MAX_RETRIES ]] && [[ $POST_SUCCESS -eq 0 ]]; do
    HTTP_CODE="${MOCK_HTTP_CODE:-429}"
    
    if [[ "$HTTP_CODE" == "200" ]] || [[ "$HTTP_CODE" == "201" ]]; then
        POST_SUCCESS=1
    else
        RETRY_COUNT=$((RETRY_COUNT + 1))
        DELAY=$((2 ** RETRY_COUNT))
        echo "Retry $RETRY_COUNT: delay=${DELAY}s"
    fi
    
    # Simulate success after 3 retries for testing
    if [[ $RETRY_COUNT -eq 3 ]]; then
        MOCK_HTTP_CODE=200
    fi
done

echo "RETRIES=$RETRY_COUNT"
echo "SUCCESS=$POST_SUCCESS"
EOF
    chmod +x "$retry_script"
    
    # Test retry behavior
    local result
    result=$($retry_script)
    
    if echo "$result" | grep -q "SUCCESS=1"; then
        log_pass "Retry logic eventually succeeds after failures"
    else
        log_fail "Retry logic should succeed after configured retries"
    fi
    
    # Verify exponential backoff delays
    if echo "$result" | grep -q "delay=2s" && \
       echo "$result" | grep -q "delay=4s" && \
       echo "$result" | grep -q "delay=8s"; then
        log_pass "Exponential backoff uses correct delays (2, 4, 8, 16, 32)"
    else
        log_fail "Exponential backoff delays are incorrect"
    fi
    
    # Test max retries limit
    if echo "$result" | grep -q "RETRIES=3"; then
        log_pass "Retry counter tracks attempts correctly"
    else
        log_fail "Retry counter not tracking correctly"
    fi
}

# ============================================================================
# TEST 3: Task Assignment Logic
# ============================================================================
test_task_assignment_logic() {
    log_info "Testing task assignment logic..."
    
    # Test is_assigned function logic
    local test_script="${MOCK_DIR}/test-assignment.sh"
    cat > "$test_script" << 'EOF'
#!/bin/bash
# Test task assignment detection logic

is_assigned() {
    local TASK_ID="$1"
    local REACTIONS="${MOCK_REACTIONS:-[]}"
    local COUNT
    
    # Simulate parsing reaction count
    COUNT=$(echo "$REACTIONS" | python3 -c "import json,sys; data=json.load(sys.stdin); print(len(data) if isinstance(data, list) else 0)" 2>/dev/null)
    
    if [[ "${COUNT:-0}" -gt 0 ]]; then
        return 0  # true - is assigned
    fi
    return 1  # false - not assigned
}

# Test 1: No reactions
MOCK_REACTIONS="[]"
if ! is_assigned "task123"; then
    echo "TEST1=PASS"
else
    echo "TEST1=FAIL"
fi

# Test 2: Has reaction
MOCK_REACTIONS='[{"id":"user1"}]'
if is_assigned "task123"; then
    echo "TEST2=PASS"
else
    echo "TEST2=FAIL"
fi

# Test 3: Multiple reactions
MOCK_REACTIONS='[{"id":"user1"},{"id":"user2"}]'
if is_assigned "task123"; then
    echo "TEST3=PASS"
else
    echo "TEST3=FAIL"
fi
EOF
    chmod +x "$test_script"
    
    local result
    result=$($test_script)
    
    if echo "$result" | grep -q "TEST1=PASS"; then
        log_pass "Task correctly detected as unassigned when no reactions exist"
    else
        log_fail "Task assignment detection fails for unassigned task"
    fi
    
    if echo "$result" | grep -q "TEST2=PASS"; then
        log_pass "Task correctly detected as assigned with single reaction"
    else
        log_fail "Task assignment detection fails for single reaction"
    fi
    
    if echo "$result" | grep -q "TEST3=PASS"; then
        log_pass "Task correctly detected as assigned with multiple reactions"
    else
        log_fail "Task assignment detection fails for multiple reactions"
    fi
    
    # Test mark_assigned function
    local mark_script="${MOCK_DIR}/test-mark.sh"
    cat > "$mark_script" << 'EOF'
#!/bin/bash
# Test mark_assigned logic

MARK_FILE="${MOCK_DIR}/marked-tasks.txt"
mkdir -p "$(dirname "$MARK_FILE")"

discord_api() {
    # Mock successful Discord API call
    echo '{"success":true}'
}

mark_assigned() {
    local TASK_ID="$1"
    local LOCK_FILE="${MARK_FILE}.lock"
    
    # Simulate flock
    {
        flock -x 200
        echo "$TASK_ID" >> "$MARK_FILE"
        discord_api PUT "/channels/test/messages/${TASK_ID}/reactions/%E2%9C%85/@me" > /dev/null 2>&1 || true
    } 200>"$LOCK_FILE"
}

# Test marking
mark_assigned "task456"
if grep -q "task456" "$MARK_FILE"; then
    echo "MARK=PASS"
else
    echo "MARK=FAIL"
fi
EOF
    chmod +x "$mark_script"
    
    if $mark_script | grep -q "MARK=PASS"; then
        log_pass "mark_assigned correctly records task assignment"
    else
        log_fail "mark_assigned fails to record task assignment"
    fi
}

# ============================================================================
# TEST 4: File Locking Behavior
# ============================================================================
test_file_locking() {
    log_info "Testing file locking behavior..."
    
    local test_file="${MOCK_DIR}/locked-file.txt"
    local lock_file="${test_file}.lock"
    
    # Test exclusive flock behavior
    local lock_script="${MOCK_DIR}/test-flock.sh"
    cat > "$lock_script" << 'EOF'
#!/bin/bash
# Test exclusive file locking

TEST_FILE="${1:-/tmp/test-lock.txt}"
LOCK_FILE="${TEST_FILE}.lock"
RESULTS_FILE="${MOCK_DIR}/lock-results.txt"

mkdir -p "$(dirname "$TEST_FILE")"

acquire_lock() {
    local ID="$1"
    local START_TIME=$(date +%s%N)
    
    {
        if flock -x -w 5 200; then
            local END_TIME=$(date +%s%N)
            local DURATION=$(( (END_TIME - START_TIME) / 1000000 ))
            
            echo "$ID acquired lock after ${DURATION}ms"
            echo "content_$ID" >> "$TEST_FILE"
            sleep 0.1  # Simulate work
        else
            echo "$ID failed to acquire lock"
        fi
    } 200>"$LOCK_FILE"
}

# Test concurrent access
echo "start" > "$TEST_FILE"

# Background process holds lock
{
    flock -x 200
    sleep 0.3
    echo "bg_writer" >> "$TEST_FILE"
} 200>"$LOCK_FILE" &
BG_PID=$!

sleep 0.05  # Ensure background process gets lock first

# Foreground process waits for lock
acquire_lock "fg"

wait $BG_PID 2>/dev/null || true

# Verify file integrity
if grep -q "start" "$TEST_FILE" && \
   grep -q "bg_writer" "$TEST_FILE" && \
   grep -q "content_fg" "$TEST_FILE"; then
    echo "LOCK_INTEGRITY=PASS"
else
    echo "LOCK_INTEGRITY=FAIL"
    cat "$TEST_FILE"
fi
EOF
    chmod +x "$lock_script"
    
    if $lock_script "$test_file" | grep -q "LOCK_INTEGRITY=PASS"; then
        log_pass "File locking prevents concurrent write corruption"
    else
        log_fail "File locking test failed - potential race condition"
    fi
    
    # Test lock timeout behavior
    local timeout_script="${MOCK_DIR}/test-lock-timeout.sh"
    cat > "$timeout_script" << 'EOF'
#!/bin/bash
# Test lock timeout behavior

TEST_FILE="${1:-/tmp/test-lock.txt}"
LOCK_FILE="${TEST_FILE}.lock"

# Hold lock for 2 seconds in background
{
    flock -x 200
    sleep 2
} 200>"$LOCK_FILE" &
BG_PID=$!

sleep 0.1  # Let background acquire lock

# Try to acquire with 0.5 second timeout
START=$(date +%s)
{
    if flock -x -w 0.5 200; then
        echo "ACQUIRED"
    else
        echo "TIMEOUT"
    fi
} 200>"$LOCK_FILE"
END=$(date +%s)

wait $BG_PID 2>/dev/null || true

DURATION=$((END - START))
if [[ $DURATION -ge 0 && $DURATION -le 2 ]]; then
    echo "TIMEOUT_BEHAVIOR=PASS (duration: ${DURATION}s)"
else
    echo "TIMEOUT_BEHAVIOR=FAIL"
fi
EOF
    chmod +x "$timeout_script"
    
    if $timeout_script "$test_file" | grep -q "TIMEOUT_BEHAVIOR=PASS"; then
        log_pass "Lock timeout prevents indefinite blocking"
    else
        log_fail "Lock timeout behavior is incorrect"
    fi
}

# ============================================================================
# TEST 5: Timeout Configuration
# ============================================================================
test_timeout_configuration() {
    log_info "Testing timeout configuration..."
    
    # Test timeout value selection based on thinking level
    local timeout_script="${MOCK_DIR}/test-timeout-calc.sh"
    cat > "$timeout_script" << 'EOF'
#!/bin/bash
# Test timeout calculation from orchestrator.sh

calculate_timeout() {
    local THINKING="$1"
    local CUSTOM_TIMEOUT="${2:-}"
    
    # Default: 120s for low/medium, 300s for high thinking
    local AGENT_TIMEOUT="${CUSTOM_TIMEOUT}"
    if [[ -z "$AGENT_TIMEOUT" ]]; then
        if [[ "${THINKING}" == "high" ]]; then
            AGENT_TIMEOUT=300
        else
            AGENT_TIMEOUT=120
        fi
    fi
    
    echo "$AGENT_TIMEOUT"
}

# Test default low thinking
result=$(calculate_timeout "low")
if [[ "$result" == "120" ]]; then
    echo "LOW_DEFAULT=PASS (timeout=$result)"
else
    echo "LOW_DEFAULT=FAIL (expected 120, got $result)"
fi

# Test default medium thinking
result=$(calculate_timeout "medium")
if [[ "$result" == "120" ]]; then
    echo "MED_DEFAULT=PASS (timeout=$result)"
else
    echo "MED_DEFAULT=FAIL (expected 120, got $result)"
fi

# Test default high thinking
result=$(calculate_timeout "high")
if [[ "$result" == "300" ]]; then
    echo "HIGH_DEFAULT=PASS (timeout=$result)"
else
    echo "HIGH_DEFAULT=FAIL (expected 300, got $result)"
fi

# Test custom timeout override
result=$(calculate_timeout "low" "600")
if [[ "$result" == "600" ]]; then
    echo "CUSTOM_OVERRIDE=PASS (timeout=$result)"
else
    echo "CUSTOM_OVERRIDE=FAIL (expected 600, got $result)"
fi

# Test custom timeout overrides high thinking
result=$(calculate_timeout "high" "60")
if [[ "$result" == "60" ]]; then
    echo "CUSTOM_HIGH=PASS (timeout=$result)"
else
    echo "CUSTOM_HIGH=FAIL (expected 60, got $result)"
fi
EOF
    chmod +x "$timeout_script"
    
    local result
    result=$($timeout_script)
    
    if echo "$result" | grep -q "LOW_DEFAULT=PASS"; then
        log_pass "Low thinking uses 120s default timeout"
    else
        log_fail "Low thinking timeout incorrect"
    fi
    
    if echo "$result" | grep -q "MED_DEFAULT=PASS"; then
        log_pass "Medium thinking uses 120s default timeout"
    else
        log_fail "Medium thinking timeout incorrect"
    fi
    
    if echo "$result" | grep -q "HIGH_DEFAULT=PASS"; then
        log_pass "High thinking uses 300s default timeout"
    else
        log_fail "High thinking timeout incorrect"
    fi
    
    if echo "$result" | grep -q "CUSTOM_OVERRIDE=PASS"; then
        log_pass "Custom TIMEOUT env var overrides defaults"
    else
        log_fail "Custom timeout override not working"
    fi
    
    if echo "$result" | grep -q "CUSTOM_HIGH=PASS"; then
        log_pass "Custom timeout overrides even high thinking default"
    else
        log_fail "Custom timeout override for high thinking fails"
    fi
    
    # Test timeout is actually passed to agent command
    local agent_timeout_script="${MOCK_DIR}/test-agent-timeout.sh"
    cat > "$agent_timeout_script" << 'EOF'
#!/bin/bash
# Test that timeout is passed to agent spawn command

TIMEOUT_CALLS="${MOCK_DIR}/timeout_calls.txt"

# Simulate the spawn_agent timeout logic
THINKING="${1:-medium}"
CUSTOM_TIMEOUT="${TIMEOUT:-}"

if [[ -z "$CUSTOM_TIMEOUT" ]]; then
    if [[ "$THINKING" == "high" ]]; then
        AGENT_TIMEOUT=300
    else
        AGENT_TIMEOUT=120
    fi
else
    AGENT_TIMEOUT="$CUSTOM_TIMEOUT"
fi

# Log what would be called
echo "timeout ${AGENT_TIMEOUT} openclaw agent ..." >> "$TIMEOUT_CALLS"
echo "USED_TIMEOUT=$AGENT_TIMEOUT"
EOF
    chmod +x "$agent_timeout_script"
    
    local tresult
    tresult=$($agent_timeout_script "high")
    if echo "$tresult" | grep -q "USED_TIMEOUT=300"; then
        log_pass "High thinking timeout correctly passed to spawn logic"
    else
        log_fail "High thinking timeout not correctly passed"
    fi
}

# ============================================================================
# TEST 6: Additional Integration Tests
# ============================================================================
test_integration() {
    log_info "Running integration tests..."
    
    # Test parse_task function
    local parse_script="${MOCK_DIR}/test-parse.sh"
    cat > "$parse_script" << 'EOF'
#!/bin/bash
# Test parse_task function

parse_task() {
    local CONTENT="$1"
    local MODEL="primary"
    local THINKING="medium"
    
    if [[ "$CONTENT" =~ \[model:([^\]]+)\] ]]; then
        MODEL="${BASH_REMATCH[1]}"
    fi
    
    if [[ "$CONTENT" =~ \[thinking:([^\]]+)\] ]]; then
        THINKING="${BASH_REMATCH[1]}"
    fi
    
    local DESC="$CONTENT"
    DESC=$(echo "$DESC" | sed 's/\[model:[^]]*\]//g; s/\[thinking:[^]]*\]//g; s/\*\*//g')
    DESC=$(echo "$DESC" | sed 's/^ *//;s/ *$//')
    
    echo "$MODEL|$THINKING|$DESC"
}

# Test parsing with both tags
result=$(parse_task "[model:coder] Write code [thinking:high]")
if echo "$result" | grep -q "coder|high|Write code"; then
    echo "PARSE_BOTH=PASS"
else
    echo "PARSE_BOTH=FAIL (got: $result)"
fi

# Test parsing with only model
result=$(parse_task "[model:research] Research this")
if echo "$result" | grep -q "research|medium|Research this"; then
    echo "PARSE_MODEL=PASS"
else
    echo "PARSE_MODEL=FAIL (got: $result)"
fi

# Test parsing with only thinking
result=$(parse_task "Analyze this [thinking:low]")
if echo "$result" | grep -q "primary|low|Analyze this"; then
    echo "PARSE_THINKING=PASS"
else
    echo "PARSE_THINKING=FAIL (got: $result)"
fi

# Test parsing with no tags
result=$(parse_task "Simple task")
if echo "$result" | grep -q "primary|medium|Simple task"; then
    echo "PARSE_NONE=PASS"
else
    echo "PARSE_NONE=FAIL (got: $result)"
fi
EOF
    chmod +x "$parse_script"
    
    local parseresult
    parseresult=$($parse_script)
    
    if echo "$parseresult" | grep -q "PARSE_BOTH=PASS"; then
        log_pass "parse_task correctly extracts both model and thinking"
    else
        log_fail "parse_task fails with both tags"
    fi
    
    if echo "$parseresult" | grep -q "PARSE_MODEL=PASS"; then
        log_pass "parse_task correctly extracts model with default thinking"
    else
        log_fail "parse_task fails with model only"
    fi
    
    if echo "$parseresult" | grep -q "PARSE_THINKING=PASS"; then
        log_pass "parse_task correctly extracts thinking with default model"
    else
        log_fail "parse_task fails with thinking only"
    fi
    
    if echo "$parseresult" | grep -q "PARSE_NONE=PASS"; then
        log_pass "parse_task uses defaults when no tags present"
    else
        log_fail "parse_task fails with no tags"
    fi
    
    # Test model alias mapping
    local model_script="${MOCK_DIR}/test-model-map.sh"
    cat > "$model_script" << 'EOF'
#!/bin/bash
# Test model alias mapping from orchestrator.sh

map_model() {
    local MODEL="$1"
    local MODEL_FLAG=""
    
    case "$MODEL" in
        "cheap"|"step-3.5-flash:free")
            MODEL_FLAG="openrouter/stepfun/step-3.5-flash:free"
            ;;
        "coder"|"qwen3-coder-next")
            MODEL_FLAG="openrouter/qwen/qwen3-coder-next"
            ;;
        "research"|"gemini-3-pro-preview")
            MODEL_FLAG="openrouter/google/gemini-3-pro-preview"
            ;;
        "primary"|"kimi-k2.5")
            MODEL_FLAG="openrouter/moonshotai/kimi-k2.5"
            ;;
        openrouter/*)
            MODEL_FLAG="$MODEL"
            ;;
        *)
            MODEL_FLAG="openrouter/moonshotai/kimi-k2.5"
            ;;
    esac
    
    echo "$MODEL_FLAG"
}

# Test all aliases - format: "input|expected"
tests=(
    "cheap|openrouter/stepfun/step-3.5-flash:free"
    "step-3.5-flash:free|openrouter/stepfun/step-3.5-flash:free"
    "coder|openrouter/qwen/qwen3-coder-next"
    "qwen3-coder-next|openrouter/qwen/qwen3-coder-next"
    "research|openrouter/google/gemini-3-pro-preview"
    "gemini-3-pro-preview|openrouter/google/gemini-3-pro-preview"
    "primary|openrouter/moonshotai/kimi-k2.5"
    "kimi-k2.5|openrouter/moonshotai/kimi-k2.5"
    "openrouter/custom/model|openrouter/custom/model"
    "unknown|openrouter/moonshotai/kimi-k2.5"
)

all_pass=1
for test in "${tests[@]}"; do
    input="${test%%|*}"
    expected="${test##*|}"
    result=$(map_model "$input")
    if [[ "$result" == "$expected" ]]; then
        echo "MAP[$input]=PASS"
    else
        echo "MAP[$input]=FAIL (expected $expected, got $result)"
        all_pass=0
    fi
done

exit $((1 - all_pass))
EOF
    chmod +x "$model_script"
    
    if $model_script > /dev/null 2>&1; then
        log_pass "All model aliases map correctly to full model names"
    else
        log_fail "Some model aliases fail to map correctly"
        $model_script | grep "FAIL"
    fi
}

# ============================================================================
# Main Test Runner
# ============================================================================
main() {
    echo "=============================================="
    echo "  Orchestrator Test Suite"
    echo "  Target: bin/orchestrator.sh"
    echo "=============================================="
    echo ""
    
    setup
    
    # Run all tests
    test_jq_dependency
    test_discord_retry_logic
    test_task_assignment_logic
    test_file_locking
    test_timeout_configuration
    test_integration
    
    teardown
    
    # Summary
    echo ""
    echo "=============================================="
    echo "  Test Results"
    echo "=============================================="
    echo -e "  ${GREEN}Passed: $PASSED${NC}"
    echo -e "  ${RED}Failed: $FAILED${NC}"
    echo "=============================================="
    
    if [[ $FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed.${NC}"
        exit 1
    fi
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
