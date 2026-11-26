#!/bin/bash
# Builds the app and packages release assets into ./dist:
#   TV-Ferry-<version>.zip   (what most people download)
#   TV-Ferry-<version>.dmg   (drag-to-Applications disk image)
#   SHA256SUMS.txt
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh
APP="dist/TV Ferry.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
rm -f dist/*.zip dist/*.dmg dist/SHA256SUMS.txt

ditto -c -k --norsrc --noextattr --keepParent "$APP" "dist/TV-Ferry-$VERSION.zip"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "TV Ferry" -srcfolder "$STAGE" -ov -format UDZO "dist/TV-Ferry-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"

( cd dist && shasum -a 256 "TV-Ferry-$VERSION.zip" "TV-Ferry-$VERSION.dmg" > SHA256SUMS.txt )
echo "Packaged:"; ls -lh dist
