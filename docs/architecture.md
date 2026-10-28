# Architecture and current limits

## Components

| Component | Responsibility | Privilege |
| --- | --- | --- |
| `Sources/RadminMac` | SwiftUI window, settings, peer presentation | Current user |
| `native/src/main.rs` | Bounded stdio commands, identity lifecycle, OpenRad runtime | Current user |
| `vendor/openrad` | Existing Radmin protocol, membership, authentication, transports | Current user |
| `native/identity-helper.c` | Stable Keychain reader/writer for a verified parent engine | Current user |
| `Sources/RadminBridge` / `CUtun` | `utun`, IPv4/Ethernet/ARP conversion and restricted routes | Limited installed root service |
| `native/src/network_test.rs` | Optional integrity/throughput test between owned endpoints | Current user |

The UI does not implement the protocol. OpenRad is vendored at a documented
revision with macOS patches; its cryptographic/wire-format implementation is
shared with its upstream clients. Windows executables and DLLs are not used.

## Adapter service

The app includes a one-time installer for a root-owned, versioned helper and a
launchd job. Installation requires macOS administrator authorization. Previous
helper versions are retained. The service is separate from the user's engine.

The service checks the local peer UID and a nonce-bound callback. It accepts a
bounded request for a Radmin IPv4 adapter, not shell commands, arbitrary routes,
or paths to executables. The engine verifies the service's root peer identity.
Disconnecting closes the adapter and its routes; the service remains available.

The adapter uses MTU 1500 and the Radmin `26.0.0.0/8` route. It does not replace
the default route. Multicast/broadcast entries are interface scoped. Root does
not receive device secrets or network passwords.

## Keychain

The device identity is stored in macOS Keychain, keyed by its canonical profile
path. Never rename/move a profile casually: that path identifies a Keychain
account. Fresh installations use Application Support. Existing legacy profiles
are deliberately reused, and `RADMIN_PROFILE_DIR` can select an explicit absolute
path for development.

The stable credential executable checks the parent engine's code signature
against a pinned identifier/certificate and requires an output pipe. It has no
networking, root privilege, or public credential-export command. Ordinary reads
and stores prohibit Keychain UI. An explicitly needed legacy migration can ask
macOS to authorize reading the previous record, then create a separate new record
owned by the stable component. The original record is retained. An existing
different identity is not overwritten or replaced by a new registration.

Credentials cached between reconnects exist only in engine memory. Network
passwords are not serialized into preferences, reports, or diagnostics. A bounded
setup log records timing/counts rather than packet contents, keys, or passwords.

## Limits

- IPv4 only; no full Ethernet bridge or IPv6 support through `utun`.
- Automatic game/LAN discovery can choose the physical Wi-Fi interface. Direct
  connections to the Radmin IP and the application's actual port are supported.
- Relay, NAT traversal, external VPNs, and network changes affect performance.
  A peer being online does not prove its game port is open.
- The current UI is Russian. Some Windows settings, roles, remote management,
  and file-transfer actions have not been implemented.
- Apple Silicon is tested. Intel builds and multi-user helper installation need
  further real-machine validation.
- Local signing is not Developer ID/notarization; changes to the signing identity
  or the stable credential component may need a new Keychain authorization.
