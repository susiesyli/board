#!/bin/bash
# Builds Board.app into ./build. Pass --install to also copy it into /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

# With only the Command Line Tools installed, the newest SDK's SwiftUI needs a macro plugin
# that ships with Xcode — so fall back to the newest macOS 26.x SDK.
if [ -z "${SDKROOT:-}" ] && [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
    SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.[0-9]*.sdk 2>/dev/null | sort -V | tail -1 || true)
    [ -n "$SDK" ] && export SDKROOT="$SDK"
fi

set +o pipefail
swift build -c release 2>&1 | grep -v "search path .* not found"
BUILD_STATUS=${PIPESTATUS[0]}
set -o pipefail
# Stop here on a failed build — otherwise the previous binary would be packaged as if it were new.
[ "$BUILD_STATUS" -eq 0 ] || { echo "build failed"; exit 1; }
BIN=.build/release/Board

APP=build/Board.app
mkdir -p build
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Board"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon, rendered by the app itself from the same aluminum used on the board.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
"$BIN" --render-icon build/icon-1024.png
for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    pkill -x Board 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/Board.app
    cp -R "$APP" /Applications/
    open /Applications/Board.app
    echo "Installed to /Applications/Board.app and launched"
fi
