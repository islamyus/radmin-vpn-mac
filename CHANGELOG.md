# Changelog

## 0.3.3 — 2026-10-28

First public macOS community release.

- Native SwiftUI client backed by a pinned OpenRad protocol engine.
- Existing private Radmin networks, direct TCP/UDP and relay, IPv4 over utun.
- One-time adapter-service installation and a separate stable Keychain component.
- Per-network peer selection, responsive rows, and recent authenticated RTT bars.
- Mac/Windows integrity and throughput test tools.
- Fresh profiles use macOS Application Support; existing development profiles
  retain their original path and device identity.
- Portable SDK discovery, privacy checks, macOS CI, English/Russian documentation,
  and preserved third-party licenses.

Apple Silicon is the tested platform. Distribution is locally signed and not
Apple notarized. IPv6, automatic LAN discovery, Intel interoperability and some
Windows-client actions remain outside the validated feature set.
