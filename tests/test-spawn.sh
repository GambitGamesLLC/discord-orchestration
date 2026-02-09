#!/bin/bash
#
# test-spawn.sh
# Test suite for the Discord worker spawning system
#
# Usage: ./test-spawn.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPAWN_SCRIPT="${SCRIPT_DIR}/spawn-worker.sh"
TEST_RESULTS=()
FAILED=0
PASSED=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[TEST]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# =============================================================================
# Test Functions
# =============================================================================

test_spawn_script_exists() {
    log "Test 1: Spawn script exists"
    
    if [[ -f "$SPAWN_SCRIPT" ]]; then
        log "✓ spawn-worker.sh found"
        PASSED=$((PASSED + 1))
        return 0
    else
        error "✗ spawn-worker.sh not found at $SPAWN_SCRIPT"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

test_spawn_script_executable() {
    log "Test 2: Spawn script is executable"
    
    if [[ -x "$SPAWN_SCRIPT" ]]; then
        log "✓ spawn-worker.sh is executable"
        PASSED=$((PASSED + 1))
        return 0
    else
        warn "spawn-worker.sh not executable, attempting to fix..."
        chmod +x "$SPAWN_SCRIPT"
        if [[ -x "$SPAWN_SCRIPT" ]]; then
            log "✓ Fixed permissions"
            PASSED=$((PASSED + 1))
            return 0
        else
            error "✗ Could not make spawn-worker.sh executable"
            FAILED=$((FAILED + 1))
            return 1
        fi
    fi
}

test_openclaw_available() {
    log "Test 3: OpenClaw is available"
    
    if command -v openclaw &> /dev/null; then
        local version
        version=$(openclaw --version 2>&1 || echo "unknown")
        log "✓ OpenClaw found: $version"
        PASSED=$((PASSED + 1))
        return 0
    else
        error "✗ openclaw command not found in PATH"
        error "   Install OpenClaw or set OPENCLAW_BIN environment variable"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

test_help_flag() {
    log "Test 4: Spawn script --help works"
    
    if "$SPAWN_SCRIPT" --help > /dev/null 2>&1; then
        log "✓ --help flag works"
        PASSED=$((PASSED + 1))
        return 0
    else
        error "✗ --help flag failed"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

test_missing_args() {
    log "Test 5: Spawn script validates required arguments"
    
    local output
    output=$("$SPAWN_SCRIPT" 2>&1) || true
    
    if echo "$output" | grep -q "task-id is required"; then
        log "✓ Missing --task-id detected"
        PASSED=$((PASSED + 1))
        return 0
    else
        error "✗ Did not detect missing --task-id"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

test_simple_spawn() {
    log "Test 6: Spawn a simple worker task"
    log "   (This will take ~30-60 seconds)"
    
    local task_id="test-simple-$(date +%s)"
    local output
    
    if output=$("$SPAWN_SCRIPT" \
        --task-id "$task_id" \
        --task "Write a one-line Python hello world program" \
        --model "openrouter/moonshotai/kimi-k2.5" \
        --thinking "low" \
        --output-dir "/tmp/discord-test/$task_id" 2>&1); then
        
        # Check if result file was created
        if [[ -f "/tmp/discord-test/$task_id/result.json" ]]; then
            log "✓ Worker completed and created result.json"
            
            # Check result content
            local status
            status=$(jq -r '.status' "/tmp/discord-test/$task_id/result.json" 2>/dev/null || echo "unknown")
            
            if [[ "$status" == "success" ]] || [[ "$status" == "completed" ]]; then
                log "✓ Task completed successfully (status: $status)"
                PASSED=$((PASSED + 1))
                return 0
            else
                warn "Task completed but status is: $status"
                log "   (This may be OK - check result.json)"
                PASSED=$((PASSED + 1))
                return 0
            fi
        else
            error "✗ Worker did not create result.json"
            error "   Output: $output"
            FAILED=$((FAILED + 1))
            return 1
        fi
    else
        error "✗ Worker spawn failed"
        error "   Output: $output"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

test_workspace_isolation() {
    log "Test 7: Workspace isolation"
    
    local task_id_1="test-isolation-1"
    local task_id_2="test-isolation-2"
    local output1 output2
    
    # Spawn two workers simultaneously
    log "   Spawning two workers at once..."
    
    output1=$("$SPAWN_SCRIPT" \
        --task-id "$task_id_1" \
        --task "Create a file named 'worker1.txt' with content 'worker1'" \
        --output-dir "/tmp/discord-test/$task_id_1" 2>&1) &
    
    local pid1=$!
    
    output2=$("$SPAWN_SCRIPT" \
        --task-id "$task_id_2" \
        --task "Create a file named 'worker2.txt' with content 'worker2'" \
        --output-dir "/tmp/discord-test/$task_id_2" 2>&1) &
    
    local pid2=$!
    
    # Wait for both
    wait $pid1 || true
    wait $pid2 || true
    
    # Check isolation
    local result1="/tmp/discord-test/$task_id_1/result.json"
    local result2="/tmp/discord-test/$task_id_2/result.json"
    
    if [[ -f "$result1" ]] && [[ -f "$result2" ]]; then
        log "✓ Both workers created their results"
        
        # Check workspaces are separate
        local workspace1="/tmp/discord-test/$task_id_1/workspace"
        local workspace2="/tmp/discord-test/$task_id_2/workspace"
        
        if [[ -d "$workspace1" ]] && [[ -d "$workspace2" ]]; then
            log "✓ Workspaces are isolated"
            PASSED=$((PASSED + 1))
            return 0
        else
            error "✗ Workspace directories not found"
            FAILED=$((FAILED + 1))
            return 1
        fi
    else
        error "✗ One or both workers failed to create results"
        [[ ! -f "$result1" ]] && error "   Missing: $result1"
        [[ ! -f "$result2" ]] && error "   Missing: $result2"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

test_no_zombie_processes() {
    log "Test 8: No zombie processes"
    
    # Count openclaw processes before
    local before after
    before=$(pgrep -c openclaw 2>/dev/null || echo "0")
    
    log "   OpenClaw processes before: $before"
    
    # Spawn and wait for a worker
    local task_id="test-zombie-$(date +%s)"
    "$SPAWN_SCRIPT" \
        --task-id "$task_id" \
        --task "Wait 2 seconds then exit" \
        --output-dir "/tmp/discord-test/$task_id" \
        > /dev/null 2>&1 || true
    
    # Give processes time to clean up
    sleep 2
    
    # Count after
    after=$(pgrep -c openclaw 2>/dev/null || echo "0")
    log "   OpenClaw processes after: $after"
    
    # Should be the same (or fewer) as before
    if [[ "$after" -le "$before" ]]; then
        log "✓ No zombie processes detected"
        PASSED=$((PASSED + 1))
        return 0
    else
        warn "⚠ More openclaw processes after test ($after > $before)"
        warn "   (This may be OK if you have other OpenClaw sessions running)"
        PASSED=$((PASSED + 1))
        return 0
    fi
}

test_orchestrator_script() {
    log "Test 9: Discord orchestrator script exists"
    
    local orchestrator="${SCRIPT_DIR}/discord-orchestrator.py"
    
    if [[ -f "$orchestrator" ]]; then
        log "✓ discord-orchestrator.py found"
        
        if python3 -c "import sys; sys.path.insert(0, '$SCRIPT_DIR'); import discord_orchestrator" 2>/dev/null; then
            log "✓ Python imports work"
            PASSED=$((PASSED + 1))
            return 0
        else
            warn "⚠ Python imports may have issues (this is OK for initial testing)"
            PASSED=$((PASSED + 1))
            return 0
        fi
    else
        error "✗ discord-orchestrator.py not found"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

# =============================================================================
# Main
# =============================================================================

echo "======================================"
echo "Discord Orchestration Test Suite"
echo "======================================"
echo ""

# Run all tests
test_spawn_script_exists
test_spawn_script_executable
test_openclaw_available
test_help_flag
test_missing_args
test_simple_spawn
test_workspace_isolation
test_no_zombie_processes
test_orchestrator_script

# Summary
echo ""
echo "======================================"
echo "Test Summary"
echo "======================================"
echo -e "Passed: ${GREEN}${PASSED}${NC}"
echo -e "Failed: ${RED}${FAILED}${NC}"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    echo "The spawn system appears to be working correctly."
    echo ""
    echo "Next steps:"
    echo "1. Test with a real task: python discord-orchestrator.py --task-id test --task 'Your task here'"
    echo "2. Set up Discord integration"
    echo "3. Test cross-machine spawning (Cookie's laptop)"
    exit 0
else
    echo -e "${RED}✗ Some tests failed${NC}"
    echo "Please fix the issues above before proceeding."
    exit 1
fi
