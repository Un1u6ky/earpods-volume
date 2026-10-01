#!/bin/zsh
set -euo pipefail

LABEL="com.earpods-volume"
UID_NUM="$(id -u)"

launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/${LABEL}.plist"
rm -rf "$HOME/Library/Application Support/EarPodsVolume"

echo "Removed the agent and the binary."
echo "Saved volume is still in ~/Library/Preferences/${LABEL}.plist"
