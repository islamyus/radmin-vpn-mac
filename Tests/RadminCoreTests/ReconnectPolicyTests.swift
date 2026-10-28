// SPDX-License-Identifier: GPL-3.0-only
import Testing
@testable import RadminCore

@Test func reconnectionRequiresAnIssuedIdentityAndDoesNotRepeatProtectedFailures() {
    #expect(ReconnectPolicy.delay(attempt: 0, knownIdentity: false, error: "timeout") == nil)
    for error in ["Cannot read device identity from macOS Keychain", "registration unknown outcome", "Administrator authorization was cancelled", "credential rejected"] {
        #expect(ReconnectPolicy.delay(attempt: 0, knownIdentity: true, error: error) == nil)
    }
    #expect(ReconnectPolicy.delay(attempt: 0, knownIdentity: true, error: "Connection reset") == 3)
    #expect(ReconnectPolicy.delay(attempt: 2, knownIdentity: true, error: "Network unreachable") == 12)
    #expect(ReconnectPolicy.delay(attempt: 100, knownIdentity: true, error: "timeout") == 30)
}

@Test func anExistingDeviceCanRetryAnInterruptedMembershipAttachment() {
    // Attachment authenticates an existing identity; it never provisions a device.
    for error in ["unexpected attachment operation 18", "attachment membership budget exhausted"] {
        #expect(ReconnectPolicy.delay(attempt: 0, knownIdentity: true, error: error) == 3)
        #expect(ReconnectPolicy.delay(attempt: 0, knownIdentity: false, error: error) == nil)
    }
    #expect(ReconnectPolicy.delay(attempt: 0, knownIdentity: true, error: "registration unknown outcome") == nil)
}
