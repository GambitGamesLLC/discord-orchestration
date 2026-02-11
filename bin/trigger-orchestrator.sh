#!/bin/bash
# trigger-orchestrator.sh - Manually trigger orchestrator to assign pending tasks

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/orchestrator-assign.sh"
