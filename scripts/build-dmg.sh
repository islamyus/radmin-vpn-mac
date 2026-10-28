#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
zsh scripts/build-app.sh
APP="$(tail -1 build/native-app-builds.txt)"
STAMP="$(date +%Y%m%d-%H%M%S)"
STAGE="$ROOT/build/dmg-$STAMP"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Radmin VPN.app"
ln -s /Applications "$STAGE/Applications"
codesign --verify --deep --strict "$STAGE/Radmin VPN.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DEST="$ROOT/dist/Radmin-VPN-Mac-$VERSION-$STAMP.dmg"
hdiutil create -volname 'Radmin VPN' -srcfolder "$STAGE" -format UDZO "$DEST"
hdiutil verify "$DEST"
print -r -- "$DEST" >> build/native-dmg-builds.txt
print -r -- "Built installer image: $DEST"
