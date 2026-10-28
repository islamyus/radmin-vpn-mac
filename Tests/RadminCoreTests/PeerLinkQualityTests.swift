// SPDX-License-Identifier: GPL-3.0-only
import Testing
@testable import RadminCore

@Test func peerBarsRequireARecentRealMeasurement() {
    #expect(PeerLinkQuality(rttMilliseconds: 237, measuredAt: 100).bars(at: 110) == 2)
    #expect(PeerLinkQuality(rttMilliseconds: 237, measuredAt: 100).bars(at: 126) == nil)
    #expect(PeerLinkQuality(rttMilliseconds: nil, measuredAt: 100).bars(at: 110) == 0)
    #expect(PeerLinkQuality(rttMilliseconds: .nan, measuredAt: 100).bars(at: 110) == nil)
    #expect(PeerLinkQuality(rttMilliseconds: -1, measuredAt: 100).bars(at: 110) == nil)
    #expect(PeerLinkQuality(rttMilliseconds: 5, measuredAt: 100).bars(at: 99) == nil)
}

@Test func latencyScaleHasExplicitBoundaries() {
    for (rtt, bars) in [(0.0, 4), (79.9, 4), (80, 3), (149.9, 3), (150, 2), (299.9, 2), (300, 1), (2000, 1)] {
        #expect(PeerLinkQuality(rttMilliseconds: rtt, measuredAt: 0).bars(at: 0) == bars)
    }
}
