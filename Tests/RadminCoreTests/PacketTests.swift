// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import RadminCore

let localMAC: [UInt8] = [2, 1, 2, 3, 4, 5]
let peerMAC: [UInt8] = [2, 6, 7, 8, 9, 10]
let localIP = IPv4("26.1.2.3")!
let peerIP = IPv4("26.4.5.6")!

func packet(from source: IPv4 = localIP, to destination: IPv4 = peerIP) -> [UInt8] {
    // Minimal IPv4 packet. Conversion does not modify the IP header or checksums.
    [0x45, 0, 0, 20, 0, 0, 0, 0, 64, 1, 0, 0] + source.bytes + destination.bytes
}
func arp(op: UInt8, source: IPv4 = peerIP, target: IPv4 = localIP, sourceMAC: [UInt8] = peerMAC) -> [UInt8] {
    localMAC + sourceMAC + [8, 6, 0, 1, 8, 0, 6, 4, 0, op] + sourceMAC + source.bytes + localMAC + target.bytes
}

@Test func strictAddresses() {
    for invalid in ["", "26.1.1", "26.1.1.1.1", "26.01.1.1", "26.256.1.1", "26.1.1.1;id", "26.1.1.-1", "26.1.1.1\n", "+26.1.1.1"] {
        #expect(IPv4(invalid) == nil)
    }
    #expect(IPv4("26.1.1.1")?.isRadmin == true)
    #expect(IPv4("192.168.1.1")?.isRadmin == false)
    #expect(IPv4("26.255.255.255")?.isRadmin == false)
}

@Test func fifoDecoderHandlesEverySplit() throws {
    let frame = localMAC + peerMAC + [8, 0] + packet()
    let record = try FrameDecoder.encode(frame)
    for split in 0...record.count {
        var decoder = FrameDecoder()
        let first = try decoder.append(Array(record.prefix(split)))
        let last = try decoder.append(Array(record.dropFirst(split)))
        #expect(first + last == [frame])
    }
}

@Test func fifoDecoderCoalescedAndFragmentedRecords() throws {
    let frame = localMAC + peerMAC + [8, 0] + packet()
    let bytes = try FrameDecoder.encode(frame) + FrameDecoder.encode(frame)
    var decoder = FrameDecoder()
    var actual: [[UInt8]] = []
    for byte in bytes { actual += try decoder.append([byte]) }
    #expect(actual == [frame, frame])
}

@Test func fifoRejectsMalformedLength() {
    var decoder = FrameDecoder()
    #expect(throws: PacketError.self) { try decoder.append([0, 0]) }
    #expect(throws: PacketError.self) { try FrameDecoder.encode([1, 2, 3]) }
}

@Test func unresolvedPeerSendsARPThenFlushesRealMAC() {
    var bridge = EthernetBridge(mac: localMAC, address: localIP)
    let requests = bridge.outgoing(packet(), now: 0)
    #expect(requests.count == 1)
    #expect(Array(requests[0][0..<6]) == [255, 255, 255, 255, 255, 255])
    #expect(Array(requests[0][12..<14]) == [8, 6])
    #expect(Array(requests[0][38..<42]) == peerIP.bytes)
    let result = bridge.incoming(arp(op: 2), now: 0.2)
    #expect(result.packets.isEmpty)
    #expect(result.replies.count == 1)
    #expect(Array(result.replies[0].prefix(6)) == peerMAC)
    #expect(Array(result.replies[0][14..<34]) == packet())
    let next = bridge.outgoing(packet(), now: 1)
    #expect(Array(next[0].prefix(6)) == peerMAC)
    #expect(Array(next[0][12..<14]) == [8, 0])
}

@Test func respondsOnlyToARPForLocalAddress() {
    var bridge = EthernetBridge(mac: localMAC, address: localIP)
    let response = bridge.incoming(arp(op: 1), now: 0)
    #expect(response.replies.count == 1)
    #expect(response.replies[0][21] == 2)
    #expect(Array(response.replies[0][28..<32]) == localIP.bytes)
    #expect(Array(response.replies[0][38..<42]) == peerIP.bytes)
    #expect(bridge.incoming(arp(op: 1, target: IPv4("26.9.9.9")!), now: 0).replies.isEmpty)
}

@Test func arpRetriesAndQueueExpire() {
    var bridge = EthernetBridge(mac: localMAC, address: localIP)
    #expect(bridge.outgoing(packet(), now: 0).count == 1)
    #expect(bridge.outgoing(packet(), now: 0.2).isEmpty)
    #expect(bridge.tick(now: 1).count == 1)
    #expect(bridge.tick(now: 2).count == 1)
    #expect(bridge.tick(now: 3).isEmpty)
    #expect(bridge.incoming(arp(op: 2), now: 4).replies.isEmpty)
}

@Test func arpQueueIsBoundedAndCacheExpires() {
    var bridge = EthernetBridge(mac: localMAC, address: localIP)
    for _ in 0..<100 { _ = bridge.outgoing(packet(), now: 0) }
    #expect(bridge.incoming(arp(op: 2), now: 1).replies.count == 8)
    let request = bridge.outgoing(packet(), now: 602)
    #expect(request.count == 1)
    #expect(request[0][13] == 6)
}

@Test func broadcastAndMulticastMapping() {
    var bridge = EthernetBridge(mac: localMAC, address: localIP)
    for address in ["255.255.255.255", "26.255.255.255"] {
        let frames = bridge.outgoing(packet(to: IPv4(address)!), now: 0)
        #expect(Array(frames[0].prefix(6)) == [255, 255, 255, 255, 255, 255])
    }
    let frames = bridge.outgoing(packet(to: IPv4("224.0.2.60")!), now: 0)
    #expect(Array(frames[0].prefix(6)) == [1, 0, 0x5e, 0, 2, 60])
    #expect(bridge.outgoing(packet(to: IPv4("8.8.8.8")!), now: 0).isEmpty)
}

@Test func incomingRemovesEthernetPadding() {
    var bridge = EthernetBridge(mac: localMAC, address: localIP)
    let ip = packet(from: peerIP, to: localIP)
    let frame = localMAC + peerMAC + [8, 0] + ip + Array(repeating: UInt8(0), count: 26)
    #expect(bridge.incoming(frame, now: 0).packets == [ip])
    let otherMAC: [UInt8] = [2, 11, 12, 13, 14, 15]
    #expect(bridge.incoming(otherMAC + Array(frame.dropFirst(6)), now: 0).packets.isEmpty)
}

@Test func rejectsTruncatedIPAndARP() {
    var bridge = EthernetBridge(mac: localMAC, address: localIP)
    #expect(bridge.outgoing(Array(packet().prefix(19)), now: 0).isEmpty)
    var oversized = packet(); oversized[3] = 60
    #expect(bridge.outgoing(oversized, now: 0).isEmpty)
    #expect(bridge.incoming(Array(arp(op: 2).prefix(30)), now: 0).replies.isEmpty)
    var malformedARP = arp(op: 2); malformedARP[18] = 8
    #expect(bridge.incoming(malformedARP, now: 0).replies.isEmpty)
}

@Test func twoMacBridgesCanExchangeIPv4WithoutLinuxTAP() {
    var first = EthernetBridge(mac: localMAC, address: localIP)
    var second = EthernetBridge(mac: peerMAC, address: peerIP)
    let original = packet()
    let request = first.outgoing(original, now: 0)
    let reply = second.incoming(request[0], now: 0.1)
    #expect(reply.replies.count == 1)
    let resolved = first.incoming(reply.replies[0], now: 0.2)
    #expect(resolved.replies.count == 1)
    let delivered = second.incoming(resolved.replies[0], now: 0.3)
    #expect(delivered.packets == [original])
}
