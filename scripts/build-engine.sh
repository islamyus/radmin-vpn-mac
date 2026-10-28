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
export CARGO_ENCODED_RUSTFLAGS="$(python3 - "$ROOT" <<'PY'
import os, shlex, sys
encoded = os.environ.get('CARGO_ENCODED_RUSTFLAGS', '')
flags = encoded.split('\x1f') if encoded else shlex.split(os.environ.get('RUSTFLAGS', ''))
home = os.path.expanduser('~')
maps = [(home, '/build'), (sys.argv[1], '/source'),
        (os.environ.get('CARGO_HOME', home + '/.cargo'), '/cargo'),
        (os.environ.get('RUSTUP_HOME', home + '/.rustup'), '/rustup')]
for original, public in sorted(maps, key=lambda pair: len(pair[0])):
    flags.append('--remap-path-prefix=' + original + '=' + public)
print('\x1f'.join(flags), end='')
PY
)"
MACOSX_DEPLOYMENT_TARGET=14.0 "$CARGO" build --manifest-path native/Cargo.toml --release --locked
python3 scripts/sign-local.py --identifier dev.radminvpn.mac.native.engine native/target/release/radmin-mac-engine
python3 scripts/sign-local.py --identifier dev.radminvpn.mac.networktest native/target/release/radmin-network-test
python3 scripts/build-identity-helper.py
"$CARGO" metadata --manifest-path native/Cargo.toml --locked --format-version 1 --filter-platform aarch64-apple-darwin > "$ROOT/build/native-cargo-metadata.json"
