// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Local UI scale based only on a recent authenticated peer ping. This is not
/// Wi-Fi strength or a claim about the Windows client's undocumented scale.
public struct PeerLinkQuality: Sendable {
    public let rttMilliseconds: Double?
    public let measuredAt: TimeInterval
    public init(rttMilliseconds: Double?, measuredAt: TimeInterval) {
        self.rttMilliseconds = rttMilliseconds
        self.measuredAt = measuredAt
    }
    public func bars(at time: TimeInterval) -> Int? {
        guard time >= measuredAt, time - measuredAt <= 25 else { return nil }
        guard let rtt = rttMilliseconds else { return 0 }
        guard rtt.isFinite, rtt >= 0 else { return nil }
        switch rtt {
        case ..<80: return 4
        case ..<150: return 3
        case ..<300: return 2
        default: return 1
        }
    }
}
