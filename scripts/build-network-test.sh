#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
zsh scripts/build-engine.sh
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$ROOT/dist/Radmin-Network-Test-$STAMP"
mkdir -p "$DEST"
cp tools/network-test/* "$DEST/"
cp tools/windows/Start-RadminNetworkTest.ps1 "$DEST/"
cp native/target/release/radmin-network-test "$DEST/"
cp LICENSE NOTICE "$DEST/"
chmod +x "$DEST/Start-Mac-Test.command" "$DEST/radmin-network-test"
if [[ -x "$ROOT/build/toolchain/cargo/bin/rustc" ]]; then
    RUST_SYSROOT="$(CARGO_HOME="$ROOT/build/toolchain/cargo" RUSTUP_HOME="$ROOT/build/toolchain/rustup" "$ROOT/build/toolchain/cargo/bin/rustc" --print sysroot)"
else
    RUST_SYSROOT="$(rustc --print sysroot)"
fi
python3 scripts/collect-rust-notices.py build/native-cargo-metadata.json "$DEST/THIRD-PARTY-NOTICES.txt" --sysroot "$RUST_SYSROOT"
ditto -c -k --sequesterRsrc --keepParent "$DEST" "$DEST.zip"
print -r -- "$DEST" >> build/network-test-builds.txt
print -r -- "Built standalone test: $DEST.zip"
