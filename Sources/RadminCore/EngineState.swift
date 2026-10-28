// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct EngineNetwork: Codable, Sendable, Identifiable {
    public let name: String
    public let networkId: String
    public var id: String { networkId }
}
public struct EnginePeer: Codable, Sendable {
    public let rid: UInt64
    public let name: String
    public let vip: String
    public let networkIds: Set<String>
}
public struct EnginePeerView: Codable, Sendable, Identifiable {
    public let peer: EnginePeer
    public let status: String
    public let detail: String
    public let transport: String?
    public var id: UInt64 { peer.rid }
}
public struct EngineTraffic: Codable, Sendable {
    public let sentBytes: UInt64
    public let receivedBytes: UInt64
    public let sentFrames: UInt64
    public let receivedFrames: UInt64
    public let dropped: UInt64
    public let receiveQueueDropped: UInt64?
    public let interfaceDropped: UInt64?
    public let invalidInboundDropped: UInt64?
    public let forwardQueueDropped: UInt64?
    public let forwardingDropped: UInt64?
    public let congestionWaits: UInt64?
}
public struct EngineSnapshot: Codable, Sendable {
    public let vip: String?
    public let networks: [EngineNetwork]
    public let peers: [String: EnginePeerView]
    public let interfaceReady: Bool
    public let interfaceError: String?
    public let traffic: EngineTraffic
    public let latencyMs: UInt32
    public var sortedPeers: [EnginePeerView] {
        peers.values.sorted { ($0.peer.name, $0.peer.rid) < ($1.peer.name, $1.peer.rid) }
    }
    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Self.self, from: data)
    }
}
