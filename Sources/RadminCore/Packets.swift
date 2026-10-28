// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct IPv4: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let byte = UInt8(part), String(byte) == part else { return nil }
            result.append(byte)
        }
        bytes = result
    }
    public init?(bytes: [UInt8]) {
        guard bytes.count == 4 else { return nil }; self.bytes = bytes
    }
    public var description: String { bytes.map(String.init).joined(separator: ".") }
    public var isRadmin: Bool { bytes[0] == 26 && bytes != [26, 0, 0, 0] && bytes != [26, 255, 255, 255] }
}

public enum PacketError: Error { case invalidLength, bufferOverflow }

/// Upstream driver's wire format: a little-endian u16 followed by an Ethernet frame.
/// The decoder preserves partial records across nonblocking FIFO reads.
public struct FrameDecoder: Sendable {
    private var buffer: [UInt8] = []
    public init() {}
    public mutating func append(_ bytes: [UInt8]) throws -> [[UInt8]] {
        guard buffer.count + bytes.count <= 131_072 else { throw PacketError.bufferOverflow }
        buffer += bytes
        var offset = 0
        var frames: [[UInt8]] = []
        while offset + 2 <= buffer.count {
            let length = Int(buffer[offset]) | (Int(buffer[offset + 1]) << 8)
            guard length >= 14, length <= 65_535 else { throw PacketError.invalidLength }
            guard offset + 2 + length <= buffer.count else { break }
            frames.append(Array(buffer[(offset + 2)..<(offset + 2 + length)]))
            offset += length + 2
        }
        if offset > 0 { buffer.removeFirst(offset) }
        return frames
    }
    public static func encode(_ frame: [UInt8]) throws -> [UInt8] {
        guard frame.count >= 14, frame.count <= 65_535 else { throw PacketError.invalidLength }
        return [UInt8(frame.count & 255), UInt8(frame.count >> 8)] + frame
    }
}

/// Converts macOS L3 utun packets to the Ethernet L2 frames expected by rvpnnetmp.
/// IPv4 only in this milestone. Unknown neighbours are resolved using real ARP,
/// bounded queues and retries; a fabricated destination MAC cannot route peers.
public struct EthernetBridge: Sendable {
    public let mac: [UInt8]
    public var address: IPv4?
    private struct Neighbour: Sendable { let mac: [UInt8]; let seen: TimeInterval }
    private struct Pending: Sendable {
        var packets: [[UInt8]] = []
        var lastRequest: TimeInterval = 0
        var attempts = 0
    }
    private var neighbours: [IPv4: Neighbour] = [:]
    private var pending: [IPv4: Pending] = [:]
    public init(mac: [UInt8], address: IPv4? = nil) {
        precondition(mac.count == 6)
        self.mac = mac; self.address = address
    }
    private func ethernet(_ payload: [UInt8], to destination: [UInt8], type: UInt16) -> [UInt8] {
        let frame = destination + mac + [UInt8(type >> 8), UInt8(type & 255)] + payload
        return frame + Array(repeating: 0, count: max(0, 60 - frame.count))
    }
    private func ipv4Packet(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count >= 20, bytes[0] >> 4 == 4 else { return nil }
        let header = Int(bytes[0] & 15) * 4
        let length = Int(bytes[2]) << 8 | Int(bytes[3])
        guard header >= 20, length >= header, bytes.count >= length else { return nil }
        return Array(bytes.prefix(length))
    }
    private func arpRequest(_ target: IPv4) -> [UInt8]? {
        guard let address else { return nil }
        let payload: [UInt8] = [0, 1, 8, 0, 6, 4, 0, 1] + mac + address.bytes
            + Array(repeating: 0, count: 6) + target.bytes
        return ethernet(payload, to: Array(repeating: 255, count: 6), type: 0x0806)
    }
    public mutating func outgoing(_ packet: [UInt8], now: TimeInterval) -> [[UInt8]] {
        guard address != nil, let packet = ipv4Packet(packet),
              let destination = IPv4(bytes: Array(packet[16..<20])) else { return [] }
        let bytes = destination.bytes
        if bytes == [255, 255, 255, 255] || bytes == [26, 255, 255, 255] {
            return [ethernet(packet, to: Array(repeating: 255, count: 6), type: 0x0800)]
        }
        if bytes[0] >= 224 && bytes[0] <= 239 {
            return [ethernet(packet, to: [1, 0, 0x5e, bytes[1] & 0x7f, bytes[2], bytes[3]], type: 0x0800)]
        }
        guard destination.isRadmin else { return [] }
        if let entry = neighbours[destination], now - entry.seen < 600 {
            return [ethernet(packet, to: entry.mac, type: 0x0800)]
        }
        guard pending[destination] != nil || pending.count < 256 else { return [] }
        var queue = pending[destination] ?? Pending()
        if queue.packets.count < 8 { queue.packets.append(packet) }
        var result: [[UInt8]] = []
        if queue.attempts == 0 || now - queue.lastRequest >= 1 {
            if let request = arpRequest(destination) { result.append(request) }
            queue.lastRequest = now; queue.attempts += 1
        }
        pending[destination] = queue
        return result
    }
    public mutating func tick(now: TimeInterval) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        for ip in Array(pending.keys) {
            guard var queue = pending[ip], now - queue.lastRequest >= 1 else { continue }
            if queue.attempts >= 3 { pending.removeValue(forKey: ip); continue }
            if let request = arpRequest(ip) { frames.append(request) }
            queue.lastRequest = now; queue.attempts += 1; pending[ip] = queue
        }
        neighbours = neighbours.filter { now - $0.value.seen < 600 }
        return frames
    }
    private mutating func learn(_ ip: IPv4, _ peerMAC: [UInt8], now: TimeInterval) -> [[UInt8]] {
        guard ip.isRadmin, ip != address, peerMAC.count == 6, peerMAC[0] & 1 == 0,
              peerMAC != [0, 0, 0, 0, 0, 0], peerMAC != mac else { return [] }
        if neighbours.count >= 1024 { neighbours = neighbours.filter { now - $0.value.seen < 600 } }
        guard neighbours.count < 1024 || neighbours[ip] != nil else { return [] }
        neighbours[ip] = Neighbour(mac: peerMAC, seen: now)
        let packets = pending.removeValue(forKey: ip)?.packets ?? []
        return packets.map { ethernet($0, to: peerMAC, type: 0x0800) }
    }
    public mutating func incoming(_ frame: [UInt8], now: TimeInterval) -> (packets: [[UInt8]], replies: [[UInt8]]) {
        guard frame.count >= 14 else { return ([], []) }
        let destination = Array(frame[0..<6])
        guard destination == mac || destination[0] & 1 == 1 else { return ([], []) }
        let source = Array(frame[6..<12])
        let type = UInt16(frame[12]) << 8 | UInt16(frame[13])
        if type == 0x0800, let packet = ipv4Packet(Array(frame.dropFirst(14))),
           let ip = IPv4(bytes: Array(packet[12..<16])) {
            return ([packet], learn(ip, source, now: now))
        }
        guard type == 0x0806, frame.count >= 42,
              Array(frame[14..<20]) == [0, 1, 8, 0, 6, 4],
              frame[20] == 0, [UInt8(1), UInt8(2)].contains(frame[21]),
              Array(frame[22..<28]) == source,
              let sender = IPv4(bytes: Array(frame[28..<32])) else { return ([], []) }
        var replies = learn(sender, source, now: now)
        if frame[21] == 1, let address, Array(frame[38..<42]) == address.bytes {
            let payload: [UInt8] = [0, 1, 8, 0, 6, 4, 0, 2] + mac + address.bytes + source + sender.bytes
            replies.append(ethernet(payload, to: source, type: 0x0806))
        }
        return ([], replies)
    }
}
