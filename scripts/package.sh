#!/bin/bash
# Build and assemble dist/Workshop.app (§4.1). Signs with the first available
# Developer ID Application identity; no sandbox (the daemon must spawn CLIs).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
DIST=dist
APP="$DIST/Workshop.app"

swift build -c release --product Workshop
swift build -c release --product workshop-daemon
swift build -c release --product workshop-mcp

BIN="$(swift build -c release --product Workshop --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" \
         "$APP/Contents/Library/LaunchAgents" \
         "$APP/Contents/Resources" \
         "$APP/Contents/Configuration"

cp "$BIN/Workshop" "$APP/Contents/MacOS/Workshop"
cp "$BIN/workshop-daemon" "$APP/Contents/MacOS/workshop-daemon"
cp "$BIN/workshop-mcp" "$APP/Contents/MacOS/workshop-mcp"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp Packaging/ai.maapu.workshop.daemon.plist \
   "$APP/Contents/Library/LaunchAgents/ai.maapu.workshop.daemon.plist"
cp Configuration/engineers.template.json \
   "$APP/Contents/Configuration/engineers.template.json" 2>/dev/null || true

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" \
    "$APP/Contents/Info.plist"

# Entitlements: none beyond the hardened-runtime defaults — the daemon spawns
# engineer CLIs, so App Sandbox is intentionally not used (ADR 0016).
IDENTITY="$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)"/\1/p' | head -1)"
if [ -z "$IDENTITY" ]; then
    # Fall back to any codesigning identity (dev machine).
    IDENTITY="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\([^"]*\)"/\1/p' | head -1)"
fi
echo "signing identity: ${IDENTITY:-<none>}"

for bin in workshop-mcp workshop-daemon Workshop; do
    if [ -n "$IDENTITY" ]; then
        codesign --force --options runtime --timestamp \
            --sign "$IDENTITY" "$APP/Contents/MacOS/$bin"
    else
        codesign --force --sign - "$APP/Contents/MacOS/$bin"
    fi
done
if [ -n "$IDENTITY" ]; then
    codesign --force --options runtime --timestamp \
        --sign "$IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi

echo "--- codesign --verify --deep --strict"
codesign --verify --deep --strict "$APP"
echo "--- spctl --assess --type execute"
spctl --assess --type execute "$APP" || true
echo "packaged: $APP (version $VERSION)"
