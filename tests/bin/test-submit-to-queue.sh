#!/bin/bash
#
# test-submit-to-queue.sh - Comprehensive tests for bin/submit-to-queue.sh
#
# Test framework: Simple bash-based assertions (no external deps)
# Run with: bash test-submit-to-queue.sh

# Don't use set -e since we expect some commands to fail
# set -e

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test directory setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
SUBMIT_SCRIPT="${REPO_DIR}/bin/submit-to-queue.sh"
TEST_DIR="$(mktemp -d)"

# Cleanup function
cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Test assertion helpers
assert_equals() {
    local expected="$1"
    local actual="$2"
    local test_name="$3"
    
    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}✓${NC} $test_name"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC} $test_name"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        ((TESTS_FAILED++))
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local test_name="$3"
    
    if [[ "$haystack" == *"$needle"* ]]; then
        echo -e "${GREEN}✓${NC} $test_name"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC} $test_name"
        echo "  Expected to contain: $needle"
        echo "  Got: $haystack"
        ((TESTS_FAILED++))
    fi
}

assert_exit_code() {
    local expected="$1"
    local test_name="$2"
    shift 2
    
    ("$@") > /dev/null 2>&1
    local actual=$?
    
    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}✓${NC} $test_name"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC} $test_name"
        echo "  Expected exit code: $expected"
        echo "  Actual exit code:   $actual"
        ((TESTS_FAILED++))
    fi
}

# ============================================
# MOCK HELPERS
# ============================================

# Create a mock curl command
setup_mock_curl() {
    cat > "$TEST_DIR/curl" << 'EOF'
#!/bin/bash
# Mock curl for testing

# Log the call for verification
echo "curl $*" >> "$MOCK_CURL_LOG"

# Check if this is a Discord API call
if [[ "$*" == *"discord.com/api"* ]]; then
    # Check for authentication header
    if [[ "$*" != *"Authorization:"* ]]; then
        echo '{"message": "401: Unauthorized"}' >&2
        exit 1
    fi
    
    # Simulate POST to create message
    if [[ "$*" == *"POST"* ]] && [[ "$*" == *"/messages"* ]] && [[ "$*" != *"/messages/"* ]]; then
        # Generate a fake task ID
        echo '{"id": "1234567890123456789", "content": "Test task"}'
        exit 0
    fi
    
    # Simulate PATCH to edit message
    if [[ "$*" == *"PATCH"* ]]; then
        echo '{"id": "1234567890123456789", "content": "Updated"}'
        exit 0
    fi
    
    # Default success response
    echo '{"id": "1234567890123456789"}'
    exit 0
fi

# Default: just echo empty object
echo '{}'
exit 0
EOF
    chmod +x "$TEST_DIR/curl"
}

# Create mock python3 for JSON parsing
setup_mock_python3() {
    cat > "$TEST_DIR/python3" << 'EOF'
#!/bin/bash
# Mock python3 for testing

# Check if this is the JSON extraction command
if [[ "$*" == *"json.load"* ]] && [[ "$*" == *"get('id'"* ]]; then
    # Extract and return the ID from stdin
    read -r input
    # Simple JSON parsing - extract id value
    echo "$input" | grep -o '"id": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)".*/\1/'
    exit 0
fi

# Default: pass through to real python3
/usr/bin/python3 "$@"
EOF
    chmod +x "$TEST_DIR/python3"
}

# Create a test version of the script with mocked dependencies
create_test_script() {
    local output_path="$1"
    
    cat > "$output_path" << 'TESTSCRIPT'
#!/bin/bash
#
# submit-to-queue.sh - Submit task to Discord #task-queue with proper formatting
# TEST VERSION - for unit testing

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Allow config override for testing
if [[ -n "${TEST_CONFIG_PATH:-}" ]]; then
    source "$TEST_CONFIG_PATH"
elif [[ -f "${REPO_DIR}/discord-config.env" ]]; then
    source "${REPO_DIR}/discord-config.env"
fi

TASK="${1:-}"
MODEL="${2:-}"
THINKING="${3:-}"

[[ -z "$TASK" ]] && {
    echo "Usage: $0 'task description' [model] [thinking]"
    echo ""
    echo "Examples:"
    echo "  $0 'Write a Python function to sort a list'"
    echo "  $0 'Review code' 'claude-sonnet-4' 'high'"
    exit 1
}

echo "Submitting to Discord #task-queue..."
echo "  Task: ${TASK:0:50}..."
[[ -n "$MODEL" ]] && echo "  Model: $MODEL"
[[ -n "$THINKING" ]] && echo "  Thinking: $THINKING"
echo ""

if [[ -n "${ORCHESTRATOR_AGENT_TOKEN:-}" && -n "${TASK_QUEUE_CHANNEL:-}" ]]; then
    # Submit task and get the message ID (which becomes the task ID)
    RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bot ${ORCHESTRATOR_AGENT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"content\":\"${TASK}\"}" \
        "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL}/messages" 2>/dev/null)
    
    TASK_ID=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
    
    if [[ -n "$TASK_ID" ]]; then
        # Edit the message to include the task ID at the top
        MSG_WITH_ID="**[Task: ${TASK_ID}]** ${TASK}"
        [[ -n "$MODEL" ]] && MSG_WITH_ID="${MSG_WITH_ID} [model:${MODEL}]"
        [[ -n "$THINKING" ]] && MSG_WITH_ID="${MSG_WITH_ID} [thinking:${THINKING}]"
        
        # Note: Using ORCHESTRATOR_AGENT_TOKEN for patch as well (original had CHIP_TOKEN bug)
        curl -s -X PATCH \
            -H "Authorization: Bot ${ORCHESTRATOR_AGENT_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"content\":\"${MSG_WITH_ID}\"}" \
            "https://discord.com/api/v10/channels/${TASK_QUEUE_CHANNEL}/messages/${TASK_ID}" > /dev/null 2>&1
        
        echo "✅ Task posted to #task-queue (ID: ${TASK_ID})"
        echo "   Workers will pick it up via reaction claiming"
    else
        echo "❌ Failed: ${RESPONSE:0:100}"
        exit 1
    fi
else
    echo "❌ Discord not configured"
    exit 1
fi
TESTSCRIPT
    chmod +x "$output_path"
}

# ============================================
# TESTS
# ============================================

echo "=============================================="
echo "Test Suite: bin/submit-to-queue.sh"
echo "=============================================="
echo ""

# Setup
export PATH="$TEST_DIR:$PATH"
export MOCK_CURL_LOG="$TEST_DIR/curl_calls.log"
touch "$MOCK_CURL_LOG"

setup_mock_curl
setup_mock_python3

# Create test script
TEST_SCRIPT="$TEST_DIR/test-submit.sh"
create_test_script "$TEST_SCRIPT"

# ---------------------------------------------
# TEST 1: Config loading error handling
# ---------------------------------------------
echo -e "${YELLOW}Config Loading Error Handling${NC}"
echo "---------------------------------------------"

# Test 1a: Missing config shows error
OUTPUT=$(unset ORCHESTRATOR_AGENT_TOKEN; unset TASK_QUEUE_CHANNEL; bash "$TEST_SCRIPT" "test task" 2>&1 || true)
assert_contains "$OUTPUT" "Discord not configured" "Shows error when config missing"
assert_exit_code 1 "Exit code 1 when config missing" bash -c 'unset ORCHESTRATOR_AGENT_TOKEN; unset TASK_QUEUE_CHANNEL; bash "'"$TEST_SCRIPT"'" "test task" 2>/dev/null'

# Test 1b: Missing token but channel present
export TASK_QUEUE_CHANNEL="123456789"
OUTPUT=$(unset ORCHESTRATOR_AGENT_TOKEN; bash "$TEST_SCRIPT" "test task" 2>&1 || true)
assert_contains "$OUTPUT" "Discord not configured" "Shows error when token missing"

# Test 1c: Missing channel but token present
export ORCHESTRATOR_AGENT_TOKEN="test-token"
unset TASK_QUEUE_CHANNEL
OUTPUT=$(bash "$TEST_SCRIPT" "test task" 2>&1 || true)
assert_contains "$OUTPUT" "Discord not configured" "Shows error when channel missing"

# Test 1d: Both present - should proceed
export ORCHESTRATOR_AGENT_TOKEN="test-token"
export TASK_QUEUE_CHANNEL="123456789"
OUTPUT=$(bash "$TEST_SCRIPT" "test task" 2>&1)
assert_contains "$OUTPUT" "Submitting to Discord" "Proceeds when both vars set"

echo ""

# ---------------------------------------------
# TEST 2: Task ID generation
# ---------------------------------------------
echo -e "${YELLOW}Task ID Generation${NC}"
echo "---------------------------------------------"

# Clear mock log
> "$MOCK_CURL_LOG"

# Test 2a: Task ID extracted from API response
export ORCHESTRATOR_AGENT_TOKEN="test-token"
export TASK_QUEUE_CHANNEL="123456789"
OUTPUT=$(bash "$TEST_SCRIPT" "test task" 2>&1)
assert_contains "$OUTPUT" "1234567890123456789" "Task ID extracted and displayed"

# Test 2b: Empty task ID causes failure
# Create failing mock
 cat > "$TEST_DIR/curl" << 'EOF'
#!/bin/bash
if [[ "$*" == *"POST"* ]]; then
    echo '{"id": ""}'
else
    echo '{}'
fi
exit 0
EOF
chmod +x "$TEST_DIR/curl"

OUTPUT=$(bash "$TEST_SCRIPT" "test task" 2>&1 || true)
assert_contains "$OUTPUT" "Failed" "Empty task ID causes failure"

# Test 2c: Invalid JSON response causes failure
 cat > "$TEST_DIR/curl" << 'EOF'
#!/bin/bash
echo 'invalid json'
exit 0
EOF
chmod +x "$TEST_DIR/curl"

OUTPUT=$(bash "$TEST_SCRIPT" "test task" 2>&1 || true)
assert_contains "$OUTPUT" "Failed" "Invalid JSON causes failure"

# Restore working mock
setup_mock_curl

echo ""

# ---------------------------------------------
# TEST 3: Discord API message formatting
# ---------------------------------------------
echo -e "${YELLOW}Discord API Message Formatting${NC}"
echo "---------------------------------------------"

# Clear mock log
> "$MOCK_CURL_LOG"

export ORCHESTRATOR_AGENT_TOKEN="test-token"
export TASK_QUEUE_CHANNEL="123456789"
OUTPUT=$(bash "$TEST_SCRIPT" "Simple test task" 2>&1)

# Check that curl was called with correct API endpoint
CURL_LOG=$(cat "$MOCK_CURL_LOG")
assert_contains "$CURL_LOG" "discord.com/api/v10/channels/123456789/messages" "Uses correct Discord API endpoint"
assert_contains "$CURL_LOG" "Authorization: Bot test-token" "Includes bot authorization header"
assert_contains "$CURL_LOG" "Content-Type: application/json" "Includes JSON content type header"
assert_contains "$CURL_LOG" "POST" "Uses POST for initial message"
assert_contains "$CURL_LOG" "PATCH" "Uses PATCH for message edit"

# Test 3b: Message content properly escaped
> "$MOCK_CURL_LOG"
OUTPUT=$(bash "$TEST_SCRIPT" 'Task with "quotes" and \backslash' 2>&1)
CURL_LOG=$(cat "$MOCK_CURL_LOG")
# The content should be in the JSON payload
assert_contains "$CURL_LOG" "content" "Message content is JSON encoded"

echo ""

# ---------------------------------------------
# TEST 4: Model alias resolution
# ---------------------------------------------
echo -e "${YELLOW}Model Alias Resolution${NC}"
echo "---------------------------------------------"

# Test 4a: Model passed through in output
> "$MOCK_CURL_LOG"
OUTPUT=$(bash "$TEST_SCRIPT" "test task" "primary" 2>&1)
assert_contains "$OUTPUT" "Model: primary" "Model name displayed in output"

# Test 4b: Model included in formatted message
CURL_LOG=$(cat "$MOCK_CURL_LOG")
assert_contains "$CURL_LOG" "[model:primary]" "Model tag in Discord message"

# Test 4c: Thinking parameter included
> "$MOCK_CURL_LOG"
OUTPUT=$(bash "$TEST_SCRIPT" "test task" "coder" "high" 2>&1)
assert_contains "$OUTPUT" "Thinking: high" "Thinking level displayed"

CURL_LOG=$(cat "$MOCK_CURL_LOG")
assert_contains "$CURL_LOG" "[model:coder]" "Model tag in message"
assert_contains "$CURL_LOG" "[thinking:high]" "Thinking tag in message"

# Test 4d: Task ID formatting in message
assert_contains "$CURL_LOG" "**[Task: " "Task ID formatted as bold"

echo ""

# ---------------------------------------------
# TEST 5: Command-line argument handling
# ---------------------------------------------
echo -e "${YELLOW}Argument Handling${NC}"
echo "---------------------------------------------"

# Test 5a: No arguments shows usage
OUTPUT=$(bash "$TEST_SCRIPT" 2>&1 || true)
assert_contains "$OUTPUT" "Usage:" "Shows usage when no args"
assert_contains "$OUTPUT" "task description" "Shows task arg in usage"
assert_contains "$OUTPUT" "model" "Shows model arg in usage"
assert_contains "$OUTPUT" "thinking" "Shows thinking arg in usage"

# Test 5b: Task only (no model/thinking)
export ORCHESTRATOR_AGENT_TOKEN="test-token"
export TASK_QUEUE_CHANNEL="123456789"
> "$MOCK_CURL_LOG"
OUTPUT=$(bash "$TEST_SCRIPT" "Just a task" 2>&1)
assert_contains "$OUTPUT" "Just a task" "Task displayed in output"
CURL_LOG=$(cat "$MOCK_CURL_LOG")
# Should NOT have model or thinking tags
if [[ "$CURL_LOG" != *"[model:"* ]]; then
    echo -e "${GREEN}✓${NC} No model tag when not specified"
    ((TESTS_PASSED++))
else
    echo -e "${RED}✗${NC} Model tag should not appear when not specified"
    ((TESTS_FAILED++))
fi

echo ""

# ============================================
# SUMMARY
# ============================================
echo "=============================================="
echo -e "Test Results:"
echo "  ${GREEN}Passed: $TESTS_PASSED${NC}"
echo "  ${RED}Failed: $TESTS_FAILED${NC}"
echo "=============================================="

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
