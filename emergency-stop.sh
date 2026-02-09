#!/bin/bash
# emergency-stop.sh - Kill all worker processes

pkill -9 -f "worker-discord"
pkill -9 -f "worker-manager"
pkill -9 -f "test-multi"
sleep 1
echo "Workers stopped: $(pgrep -f "worker-discord" | wc -l) remaining"
