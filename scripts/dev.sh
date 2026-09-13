#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build

APP=.build/Workshop.app
rm -rf "$APP"
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
open "$APP"
