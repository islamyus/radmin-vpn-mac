# Vendored OpenRad snapshot

Upstream: <https://github.com/gringoestrangeiro/openrad>

Revision: `47eb54f6b051aadc37260d405681b2111b50b7cc` (2.0.1).
Original author notices and the MIT license are preserved. `UPSTREAM.json`
records the baseline and patch areas. This copy is included so a source checkout
builds without fetching an unpinned fork.

The macOS-specific `src/platform/macos.rs` module is a GPL-3.0-only addition;
the containing macOS application is GPL-3.0-only. The original upstream code
retains its MIT notices. Project GPL text is at the repository root.

Local changes add a native utun boundary and cancellation; bounded Darwin queues,
backpressure/drop accounting, socket readiness/wake handling, portable tests,
control-packet headroom, and setup diagnostics. Attachment failures are described
as attachment errors, distinct from provisioning a new identity. The adapter's
privileged service and credential components are in the parent project.

The upstream desktop, Android, Python, documentation and packaging sources are
retained as part of the reference snapshot; they are not the macOS application.
