#!/bin/bash
# Builds Board.app and zips it, ready to attach to a GitHub Release.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
ZIP="build/Board-$VERSION.zip"
rm -f "$ZIP"
# ditto keeps the app bundle's structure and signature intact (plain `zip` can break them).
ditto -c -k --keepParent build/Board.app "$ZIP"
echo "Ready to upload: $ZIP"
