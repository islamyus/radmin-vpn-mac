#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
if [[ -x "$ROOT/build/toolchain/cargo/bin/cargo" ]]; then
    export CARGO_HOME="$ROOT/build/toolchain/cargo"
    export RUSTUP_HOME="$ROOT/build/toolchain/rustup"
    CARGO="$CARGO_HOME/bin/cargo"
else
    CARGO="$(command -v cargo)"
fi
MACOSX_DEPLOYMENT_TARGET=14.0 "$CARGO" build --manifest-path native/Cargo.toml --release --locked
python3 scripts/sign-local.py --identifier dev.radminvpn.mac.native.engine native/target/release/radmin-mac-engine
python3 scripts/sign-local.py --identifier dev.radminvpn.mac.networktest native/target/release/radmin-network-test
python3 scripts/build-identity-helper.py
"$CARGO" metadata --manifest-path native/Cargo.toml --locked --format-version 1 --filter-platform aarch64-apple-darwin > "$ROOT/build/native-cargo-metadata.json"
