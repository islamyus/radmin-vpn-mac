# Troubleshooting

## A peer is visible but a game cannot connect

Use the peer's Radmin `26.x.x.x` address and the **actual application port**.
For Minecraft Java, the host must open its world to LAN and use the port shown
in that world's chat. A single extra digit identifies a different port.

Try direct connection rather than relying on LAN discovery. Check compatible
game/mod versions and whether the host application is allowed by its firewall.
A successful ping verifies IP reachability; it does not verify a TCP listener.
Do not disable the entire firewall to diagnose one application.

## macOS requests a password

The first adapter-service installation asks for administrator authorization.
A separate Keychain request concerns the saved Radmin device. Upgrading an older
development build or replacing signing/credential components may require a
one-time migration. Enter passwords only in the local macOS dialog, never in a
GitHub issue or a test report. Do not delete the profile to clear a permission
error: that can lose the association with the existing device.

The adapter service should be reused across normal reconnects. If requests repeat,
report the app version and which dialog appears, with personal information hidden.

## Latency, bars, relay and another VPN

Bars represent recent authenticated peer RTT, not Wi-Fi strength and not the
Windows client's exact rating. Relay means packets travel through an intermediate
server. The route and endpoints of a separate VPN can change both latency and
available direct paths. Compare controlled tests before changing settings.

## Network-test port already in use

The default test port is `48671`. A previous test server may still own it. Close
only that test's PowerShell window or wait for its time limit; then restart the
test. The server prints `Ready` only after both TCP and UDP have opened.

Share the minimal error and a redacted report. Reports may contain virtual
addresses and network conditions; raw captures and identities stay private.
