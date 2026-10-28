# Security

Please use this repository's **Security → Report a vulnerability** to disclose a
security issue privately. Include the affected version, a minimal reproduction
using synthetic data, the impact, and any relevant environment details.

Do not post credentials, Keychain exports, private signing material, or raw
captures in public issues. Ordinary bugs can be reported in Issues with personal
details removed. This project has no guaranteed security-response SLA.

The protocol engine and Keychain component run as the current user. The root
service handles only a restricted virtual adapter. Device secrets stay in macOS
Keychain; the network password is not written to application preferences or logs.
See [the architecture](docs/architecture.md) for the boundaries and limitations.

Local development signing is not Apple Developer ID signing or notarization.
Retain the ignored signing/helper cache when updating a source-built app: replacing
the credential component or signing identity may require a new Keychain approval.
