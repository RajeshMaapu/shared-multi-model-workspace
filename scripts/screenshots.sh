#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build

EVIDENCE=docs/evidence/phase1
mkdir -p "$EVIDENCE"
APP=.build/Workshop.app
if [ ! -d "$APP" ]; then
    mkdir -p "$APP/Contents/MacOS"
    cp .build/debug/Workshop "$APP/Contents/MacOS/Workshop"
    cp .build/debug/workshop-daemon "$APP/Contents/MacOS/workshop-daemon"
    cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>ai.maapu.workshop</string>
    <key>CFBundleName</key>
    <string>Workshop</string>
    <key>CFBundleExecutable</key>
    <string>Workshop</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
PLIST
    codesign --force --sign - "$APP"
fi

THROWAWAY_HOME=$(mktemp -d /tmp/workshop-home.XXXXXX)
THROWAWAY_RUNTIME=$(mktemp -d /tmp/wsrt.XXXXXX)
DAEMON_PID=""

cleanup() {
    if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
        kill "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    rm -rf "$THROWAWAY_HOME" "$THROWAWAY_RUNTIME"
}
trap cleanup EXIT

capture() {
    local size="$1" appearance="$2" out="$3"
    WORKSHOP_HOME="$THROWAWAY_HOME" \
    WORKSHOP_RUNTIME_DIR="$THROWAWAY_RUNTIME" \
    WORKSHOP_ADAPTERS=fake \
    WORKSHOP_DAEMON_PATH="$PWD/.build/debug/workshop-daemon" \
    WORKSHOP_APPEARANCE="$appearance" \
    WORKSHOP_WINDOW_SIZE="$size" \
    WORKSHOP_SEED_TASK="Research caching architecture|||Propose a combined caching architecture with validation plan." \
    WORKSHOP_SCREENSHOT_PATH="$PWD/$EVIDENCE/$out" \
    open -W "$APP" || true
    # If a throwaway daemon is still running, stop only the one we spawned below.
}

# Start the throwaway daemon explicitly so we own its PID.
WORKSHOP_HOME="$THROWAWAY_HOME" \
WORKSHOP_RUNTIME_DIR="$THROWAWAY_RUNTIME" \
WORKSHOP_ADAPTERS=fake \
.build/debug/workshop-daemon &
DAEMON_PID=$!
sleep 0.5

capture "1440x960" "light" "main-1440x960-light.png"
capture "1440x960" "dark" "main-1440x960-dark.png"
capture "980x680" "light" "main-980x680-light.png"
capture "980x680" "dark" "main-980x680-dark.png"

echo "Screenshots written to $EVIDENCE"
