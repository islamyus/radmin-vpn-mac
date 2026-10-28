// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Narrow privileged operation: attach one Radmin utun to this user's socket.
public struct BridgeServiceRequest: Codable, Sendable {
    public let socket: String
    public let nonce: String
    public let vip: String
    public func arguments(owner: UInt32) throws -> [String] {
        guard owner > 0, nonce.utf8.count == 32,
              nonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              socket.hasPrefix("/"), !socket.utf8.contains(0), socket.utf8.count < 104,
              URL(fileURLWithPath: socket).standardizedFileURL.path == socket,
              socket.hasSuffix("/utun-\(nonce.prefix(12))/bridge.sock"),
              let address = IPv4(vip), address.isRadmin else { throw CocoaError(.fileReadCorruptFile) }
        return ["--socket", socket, "--nonce", nonce, "--vip", address.description, "--owner", String(owner)]
    }
}
