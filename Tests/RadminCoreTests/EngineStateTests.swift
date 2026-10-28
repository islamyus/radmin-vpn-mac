// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import RadminCore

@Test func decodesLiveEngineSchemaAndPreservesLargePeerIdentity() throws {
    let data = Data(#"{"vip":"26.1.2.3","networks":[{"name":"Synthetic","network_id":"abcd"}],"peers":{"18446744073709551614":{"peer":{"rid":18446744073709551614,"name":"Windows","vip":"26.4.5.6","state":1,"network_ids":["abcd"]},"status":"Connected","detail":"Authenticated","transport":"DirectTcp"}},"interface_ready":true,"interface_error":null,"traffic":{"sent_bytes":3200,"received_bytes":2400,"sent_frames":4,"received_frames":3,"dropped":1},"latency_ms":51}"#.utf8)
    let snapshot = try EngineSnapshot.decode(data)
    #expect(snapshot.interfaceReady)
    #expect(snapshot.networks[0].id == "abcd")
    #expect(snapshot.sortedPeers[0].id == UInt64.max - 1)
    #expect(snapshot.sortedPeers[0].transport == "DirectTcp")
    #expect(snapshot.traffic.receivedBytes == 2400)
}
