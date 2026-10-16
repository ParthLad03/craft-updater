#!/bin/sh
# Builds CraftUpdater and registers it with launchd. Nothing runs in the background: launchd
# starts CraftUpdater only when a Craft app opens (each app starts a fresh log file in
# ~/Library/Application Support/<App>/logs at launch, and launchd watches those folders).
# Re-run this after installing another Craft app so its folder is watched too.
set -eu

cd "$(dirname "$0")"
LABEL=local.craft-updater
DEST="$HOME/Library/Application Support/CraftUpdater"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p build "$DEST" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
swiftc -O -swift-version 5 -o build/craft-updater Sources/main.swift
codesign --force --sign - build/craft-updater
/bin/cp -f build/craft-updater "$DEST/craft-updater"

# One watched folder per installed Craft app (bundle id ai.storyteller.*).
WATCH=""
for app in /Applications/*.app "$HOME"/Applications/*.app; do
    [ -d "$app" ] || continue
    id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)
    case "$id" in
        ai.storyteller.*)
            name=$(basename "$app" .app)
            dir="$HOME/Library/Application Support/$name/logs"
            mkdir -p "$dir"
            WATCH="$WATCH        <string>$dir</string>
"
            echo "watching $name"
            ;;
    esac
done
if [ -z "$WATCH" ]; then
    echo "no Craft apps found in /Applications or ~/Applications" >&2
    exit 1
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$DEST/craft-updater</string></array>
    <key>WatchPaths</key>
    <array>
$WATCH    </array>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "CraftUpdater installed. It runs only when a Craft app opens. Log: ~/Library/Logs/CraftUpdater.log"
