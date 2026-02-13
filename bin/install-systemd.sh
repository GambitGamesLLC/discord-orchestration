#!/bin/bash
#
# install-systemd.sh - Install systemd timer/oneshot for discord-orchestrator
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Discord Orchestrator Systemd Installation ==="
echo ""

# Check systemd is available
if ! command -v systemctl &>/dev/null; then
    echo "Error: systemctl not found. Is this a systemd-based system?"
    exit 1
fi

# Create user systemd directory if needed
USER_SYSTEMD_DIR="${HOME}/.config/systemd/user"
mkdir -p "$USER_SYSTEMD_DIR"

# Copy unit files
cp "${REPO_DIR}/systemd/orchestrator.service" "${USER_SYSTEMD_DIR}/"
cp "${REPO_DIR}/systemd/orchestrator.timer" "${USER_SYSTEMD_DIR}/"

# Update paths in service file to match current user
sed -i "s|/home/derrick|${HOME}|g" "${USER_SYSTEMD_DIR}/orchestrator.service"

echo "✓ Installed systemd unit files to ${USER_SYSTEMD_DIR}"
echo ""

# Reload systemd
systemctl --user daemon-reload

# Enable timer (persist across reboots)
systemctl --user enable orchestrator.timer

echo "✓ Timer enabled"
echo ""

# Start timer now
systemctl --user start orchestrator.timer

echo "✓ Timer started"
echo ""

echo "=== Status ==="
systemctl --user status orchestrator.timer --no-pager

echo ""
echo "=== Next Run ==="
systemctl --user list-timers orchestrator.timer --no-pager

echo ""
echo "Commands to manage:"
echo "  Status:  systemctl --user status orchestrator.timer"
echo "  Logs:    journalctl --user -u orchestrator.service -f"
echo "  Stop:    systemctl --user stop orchestrator.timer"
echo "  Restart: systemctl --user restart orchestrator.timer"
