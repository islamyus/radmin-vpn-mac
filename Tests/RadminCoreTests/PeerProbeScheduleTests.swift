// SPDX-License-Identifier: GPL-3.0-only
import Testing
@testable import RadminCore

@Test func newConnectionIsProbedImmediatelyAndPendingProbeNeverOverlaps() {
    var schedule = PeerProbeSchedule()
    #expect(schedule.due(connected: [1], pending: [], at: 100) == [1])
    schedule.sent(to: 1, at: 100)
    #expect(schedule.due(connected: [1], pending: [], at: 101.99).isEmpty)
    #expect(schedule.due(connected: [1], pending: [], at: 102) == [1])
    #expect(schedule.due(connected: [1], pending: [1], at: 110).isEmpty)
    // A timed-out request can retry as soon as it finishes, rather than waiting
    // another full interval after receiving the timeout result.
    #expect(schedule.due(connected: [1], pending: [], at: 110) == [1])
}

@Test func reconnectAndTransportChangeDiscardOldSchedule() {
    var schedule = PeerProbeSchedule()
    schedule.sent(to: 1, at: 100)
    schedule.retain([])
    #expect(schedule.due(connected: [1], pending: [], at: 100.1) == [1])
    schedule.sent(to: 1, at: 100.1)
    schedule.forget(1)
    #expect(schedule.due(connected: [1], pending: [], at: 100.2) == [1])
}

@Test func boundedProbeBatchesDoNotStarveUnmeasuredPeers() {
    var schedule = PeerProbeSchedule()
    let peers = Set((1...12).map(UInt64.init))
    let first = schedule.due(connected: peers, pending: [], at: 100)
    #expect(first == Array(1...8).map(UInt64.init))
    for id in first { schedule.sent(to: id, at: 100) }
    #expect(schedule.due(connected: peers, pending: Set(first), at: 101) == Array(9...12).map(UInt64.init))
}
