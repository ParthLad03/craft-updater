#!/bin/sh
# Stops CraftUpdater and removes it. Your apps are left as they are.
set -eu

LABEL=local.craft-updater
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Library/Application Support/CraftUpdater"
echo "CraftUpdater removed. (Log left at ~/Library/Logs/CraftUpdater.log)"
