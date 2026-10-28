// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Probe established authenticated channels, without overlapping requests.
public struct PeerProbeSchedule: Sendable {
    private var lastSent: [UInt64: TimeInterval] = [:]
    public init() {}

    public mutating func retain(_ connected: Set<UInt64>) {
        lastSent = lastSent.filter { connected.contains($0.key) }
    }

    public mutating func forget(_ peer: UInt64) { lastSent.removeValue(forKey: peer) }

    public mutating func sent(to peer: UInt64, at time: TimeInterval) {
        lastSent[peer] = time
    }

    public func due(connected: Set<UInt64>, pending: Set<UInt64>, at time: TimeInterval) -> [UInt64] {
        Array(connected.filter {
            !pending.contains($0) && time - (lastSent[$0] ?? -.infinity) >= 2
        }.sorted {
            let lhs = lastSent[$0] ?? -.infinity, rhs = lastSent[$1] ?? -.infinity
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }.prefix(8))
    }
}
