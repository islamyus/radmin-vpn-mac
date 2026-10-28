# Contributing

Use focused pull requests and describe the observable change, its reason, and
the checks you ran. Russian or English issue descriptions are welcome.

## Development

Read [docs/building.md](docs/building.md) first. The active interface is
`RadminWindow` / `RadminPreferences`; protocol work belongs in the shared native
engine, not the SwiftUI views. The vendored OpenRad revision and changes are
documented in `vendor/openrad/UPSTREAM.json` and `LOCAL_CHANGES.md`.

- Preserve identity, network membership, cryptographic chaining, frame ordering,
  and bounded queues. Do not invent successful joins or connected peers.
- Keep the engine unprivileged. The adapter service must not accept arbitrary
  commands, executable paths, routes, or credential data.
- Keep tests headless and unprivileged by default. Use synthetic identities and
  local sockets. Live registration and changes to real networks require an
  explicit manual test, not a default test run.
- Report real Windows interoperability separately from unit/loopback tests.
- Keep vendor changes focused and retain upstream author/license notices.

Before submitting, run the relevant Swift/Rust tests and
`python3 scripts/check-public-source.py`. Keychain regressions use a separate
project keychain; they must never inspect a contributor's real VPN credentials.

## Reports and privacy

Include app/macOS version, CPU architecture, the error, and whether the peer uses
direct TCP, direct UDP, or relay. Replace device names, network names, and virtual
addresses with examples. Do not commit runtime profiles, captures, reports,
private certificates, signing keys, Keychain databases, or build outputs.

For vulnerabilities, follow [SECURITY.md](SECURITY.md).
