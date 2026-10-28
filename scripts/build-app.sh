#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
zsh scripts/build-engine.sh
swift build -c release -Xswiftc -file-prefix-map -Xswiftc "$HOME=/build" \
    -Xswiftc -file-prefix-map -Xswiftc "$ROOT=/source" \
    -Xcc "-ffile-prefix-map=$HOME=/build" -Xcc "-ffile-prefix-map=$ROOT=/source"
BIN="$(swift build -c release --show-bin-path)"
STAMP="$(date +%Y%m%d-%H%M%S)"
APP="$ROOT/dist/Radmin VPN Native-$STAMP.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/AppIcon-native-$STAMP.iconset"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/RadminVPN" "$BIN/radmin-bridge" "$APP/Contents/MacOS/"
cp native/target/release/radmin-mac-engine "$APP/Contents/MacOS/"
cp native/target/release/radmin-identity-helper "$APP/Contents/MacOS/"
cp LICENSE NOTICE README.md "$APP/Contents/Resources/"
cp vendor/openrad/LICENSE "$APP/Contents/Resources/OpenRad-LICENSE"
cp vendor/openrad/UPSTREAM.json "$APP/Contents/Resources/OpenRad-UPSTREAM.json"
if [[ -x "$ROOT/build/toolchain/cargo/bin/rustc" ]]; then
    RUST_SYSROOT="$(CARGO_HOME="$ROOT/build/toolchain/cargo" RUSTUP_HOME="$ROOT/build/toolchain/rustup" "$ROOT/build/toolchain/cargo/bin/rustc" --print sysroot)"
else
    RUST_SYSROOT="$(rustc --print sysroot)"
fi
python3 scripts/collect-rust-notices.py build/native-cargo-metadata.json "$APP/Contents/Resources/THIRD-PARTY-NOTICES.txt" --sysroot "$RUST_SYSROOT"
swift scripts/make-icon.swift "$ROOT/build/AppIcon-native-$STAMP.iconset"
iconutil -c icns "$ROOT/build/AppIcon-native-$STAMP.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
python3 scripts/sign-local.py --identifier dev.radminvpn.mac.native.bridge "$APP/Contents/MacOS/radmin-bridge"
cp scripts/install-bridge-service.sh "$APP/Contents/Resources/"
shasum -a 256 "$APP/Contents/MacOS/radmin-bridge" | cut -d ' ' -f 1 > "$APP/Contents/Resources/bridge.sha256"
codesign --verify --strict "$APP/Contents/MacOS/radmin-mac-engine"
python3 scripts/sign-local.py --identifier dev.radminvpn.mac.native "$APP"
codesign --verify --deep --strict "$APP"
# Do not ship Windows executables, DLLs, drivers or compatibility runtimes.
if find "$APP" -type f \( -iname '*.exe' -o -iname '*.dll' -o -iname '*.sys' \) | read -r unexpected; then
    print -u2 "Unexpected Windows artifact: $unexpected"; exit 1
fi
print -r -- "$APP" >> build/native-app-builds.txt
print -r -- "Built native app: $APP"
