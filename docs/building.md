# Building and packaging

## Requirements

- macOS 14 or later. Real peer interoperability has been tested on Apple Silicon.
- Xcode with Swift 6 and macOS SDK/command-line tools.
- Rust 1.95 or later with Cargo; Python 3; macOS `codesign`, `openssl`, `iconutil`,
  and `hdiutil` tools.

The helper compiler discovers the installed SDK through `xcrun`. Set
`DEVELOPER_DIR` if Xcode is installed in a nonstandard location. The build prefers
the usual full Xcode installation when present. Rust can come from your PATH or
the optional ignored `build/toolchain/` development installation.

OpenRad's Unix-socket fixtures require a short temporary-directory path. If a
library test reports `data directory path is too long for a Unix socket`, set
`TMPDIR` to an existing short, private directory before running it. CI uses the
runner's short temporary root rather than the longer checkout path.

## Package

```sh
zsh scripts/build-dmg.sh
```

This builds the engine, the SwiftUI app and adapter service, generates an original
app icon and dependency notices, signs the executables, then creates a DMG with
one application and an Applications shortcut. Previous timestamped builds remain
in `dist/`. `scripts/build-app.sh` produces just the `.app`.

The app bundles the native engine and helpers. It does not need Rust, Python,
Wine, Homebrew, Windows components, or proprietary binaries on the destination Mac.

## Signing

`scripts/sign-local.py` creates a private project keychain and self-signed code
signing identity in `build/local-signing/`. It does not install a system trust
root. These materials are ignored by Git and excluded from the app/DMG.

Keep this directory and `build/identity-helper/` private and backed up if you
intend to update the same source-built installation. Ordinary engine/UI builds
reuse the small signed Keychain executable byte for byte. A change to that
component or the certificate itself requires a separate migration plan.

The resulting development signature is **not Developer ID or notarization**.
No distribution certificate or private signing material is published here.

## Checks

```sh
swift test
cargo test --manifest-path native/Cargo.toml --locked
cargo test --manifest-path vendor/openrad/Cargo.toml --lib --locked
zsh scripts/build-engine.sh
python3 scripts/test-identity-helper.py
python3 scripts/test-network-probe.py
python3 scripts/check-public-source.py
```

The Keychain fixture uses only the separate project keychain and synthetic values.
The loopback network test verifies the test protocol and SHA-256 checks, not VPN
throughput. Neither default test suite joins a real Radmin network or installs the
privileged helper. GitHub Actions runs the same source/package checks on macOS.

## Optional Mac/Windows network test

```sh
zsh scripts/build-network-test.sh
```

Extract the generated ZIP on both owned computers. Run `Start-Windows-Test.cmd`
first and enter the actual Radmin addresses. After `Ready`, run
`Start-Mac-Test.command`. Keep both peers in the same Radmin network. The test
checks both transfer directions, SHA-256, and UDP before/during/after load.

Results are written to a new private `Reports/` directory beside the test. They
can contain addresses and network conditions; redact them before sharing. The
test does not change the firewall, routes, VPN mode, or PowerShell execution policy.
