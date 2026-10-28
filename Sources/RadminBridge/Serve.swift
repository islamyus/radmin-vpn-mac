// SPDX-License-Identifier: GPL-3.0-only
import CUtun
import Darwin
import Foundation
import RadminCore

private enum BridgeFailure: Error { case arguments, system(String), malformed, queueFull }
private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw BridgeFailure.system(message) }
}
private func configure(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output; process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data.prefix(4096), as: UTF8.self)
    try check(process.terminationStatus == 0, "\(executable): \(text)")
    return text
}
private func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) throws {
    var offset = 0
    while offset < bytes.count {
        let count = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
        if count < 0 && errno == EINTR { continue }
        try check(count > 0, "Local helper write failed")
        offset += count
    }
}

/// Root process owns one new utun. All cryptography and network credentials
/// remain in the unprivileged OpenRad process. EOF tears down the interface.
func serveInterface(_ arguments: [String]) throws {
    guard geteuid() == 0, arguments.count == 8 else { throw BridgeFailure.arguments }
    var options: [String: String] = [:]
    for offset in stride(from: 0, to: arguments.count, by: 2) {
        guard ["--socket", "--nonce", "--vip", "--owner"].contains(arguments[offset]),
              options[arguments[offset]] == nil else { throw BridgeFailure.arguments }
        options[arguments[offset]] = arguments[offset + 1]
    }
    guard let path = options["--socket"], path.hasPrefix("/"),
          let owner = options["--owner"].flatMap(UInt32.init), owner > 0,
          let nonce = options["--nonce"], nonce.utf8.count == 32,
          nonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
          let address = options["--vip"].flatMap(IPv4.init), address.isRadmin else { throw BridgeFailure.arguments }
    let socket = rvpn_connect_bridge(path, owner)
    try check(socket >= 0, "Local engine authentication failed")
    defer { close(socket) }
    var announced = false
    do {
    var name = [CChar](repeating: 0, count: 64)
    let utun = rvpn_open_utun(&name, name.count)
    try check(utun >= 0, "utun: \(String(cString: strerror(errno)))")
    defer { close(utun) } // macOS removes this interface and its interface routes.
    let interface = String(decoding: name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    try check(interface.hasPrefix("utun") && interface.dropFirst(4).allSatisfy(\.isNumber), "Unexpected interface name")
    _ = try configure("/sbin/ifconfig", [interface, "inet", address.description, address.description,
                                      "netmask", "255.0.0.0", "mtu", "1500", "up"])
    // macOS already owns global multicast/broadcast routes on the physical NIC.
    // Interface-scoped entries coexist with them; never replace the LAN routes.
    for (kind, destination, lookup) in [("-net", "26.0.0.0/8", "26.0.0.0"),
                                       ("-net", "224.0.0.0/4", "224.0.0.1"),
                                       ("-host", "255.255.255.255", "255.255.255.255")] {
        let scope = destination == "26.0.0.0/8" ? [] : ["-ifscope", interface]
        do { _ = try configure("/sbin/route", ["-n", "add", kind, destination, "-interface", interface] + scope) }
        catch {
            // ifconfig may have already installed the route on this fresh utun.
            // Refuse to replace a route owned by any other interface.
            let route = try configure("/sbin/route", ["-n", "get"] + scope + [lookup])
            let belongs = route.split(separator: "\n").contains { line in
                line.trimmingCharacters(in: .whitespaces) == "interface: \(interface)"
            }
            try check(belongs, "A VPN route already belongs to another interface")
        }
    }
    try writeAll(socket, Array(nonce.utf8) + [1])
    announced = true
    try check(fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK) == 0, "Cannot make local socket nonblocking")
    try check(fcntl(utun, F_SETFL, fcntl(utun, F_GETFL) | O_NONBLOCK) == 0, "Cannot make utun nonblocking")
    let ip = address.bytes
    var bridge = EthernetBridge(mac: [2, 0x1a] + ip, address: address)
    var decoder = RadminRecordDecoder(maximumBodyLength: 1514)
    var outgoing = Data(), offset = 0
    var packetQueue: [[UInt8]] = []
    var readBuffer = [UInt8](repeating: 0, count: 2048)
    func enqueue(_ frames: [[UInt8]]) throws {
        for frame in frames {
            guard outgoing.count - offset < 512 * 1024 else { throw BridgeFailure.queueFull }
            outgoing.append(try RadminRecordDecoder.encode(Data(frame), maximumBodyLength: 1514))
        }
    }
    var lastTick = ProcessInfo.processInfo.systemUptime
    while true {
        var descriptors = [pollfd(fd: socket, events: Int16(POLLIN | (offset < outgoing.count ? POLLOUT : 0)), revents: 0),
                           pollfd(fd: utun, events: Int16(POLLIN | (!packetQueue.isEmpty ? POLLOUT : 0)), revents: 0)]
        let result = poll(&descriptors, 2, 100)
        if result < 0 && errno == EINTR { continue }
        try check(result >= 0, "Interface poll failed")
        if descriptors[0].revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return }
        if descriptors[1].revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { throw BridgeFailure.system("utun closed") }
        let now = ProcessInfo.processInfo.systemUptime
        if descriptors[0].revents & Int16(POLLIN) != 0 {
            // A partial 1518-byte record plus an arbitrary 2048-byte read can
            // exceed the decoder's two-record budget during a download burst.
            let count = read(socket, &readBuffer, min(readBuffer.count, decoder.maximumReadLength))
            if count == 0 { return }
            if count > 0 {
                for frame in try decoder.append(Data(readBuffer.prefix(count))) {
                    guard frame.count >= 14 else { throw BridgeFailure.malformed }
                    let received = bridge.incoming(Array(frame), now: now)
                    if packetQueue.count + received.packets.count <= 256 { packetQueue += received.packets }
                    try enqueue(received.replies)
                }
            } else if errno != EAGAIN && errno != EINTR { throw BridgeFailure.system("Local socket read failed") }
        }
        if descriptors[1].revents & Int16(POLLIN) != 0 {
            let count = read(utun, &readBuffer, readBuffer.count)
            if count > 4 && Array(readBuffer[0..<4]) == [0, 0, 0, UInt8(AF_INET)] {
                try enqueue(bridge.outgoing(Array(readBuffer[4..<count]), now: now))
            } else if count < 0 && errno != EAGAIN && errno != EINTR { throw BridgeFailure.system("utun read failed") }
        }
        if now - lastTick >= 1 { try enqueue(bridge.tick(now: now)); lastTick = now }
        // A datagram write either writes the entire IP packet or leaves it queued.
        if !packetQueue.isEmpty {
            let data = [0, 0, 0, UInt8(AF_INET)] + packetQueue[0]
            let count = data.withUnsafeBytes { write(utun, $0.baseAddress, $0.count) }
            if count == data.count { packetQueue.removeFirst() }
            else if count >= 0 || (errno != EAGAIN && errno != EINTR) { throw BridgeFailure.system("utun write failed") }
        }
        if offset < outgoing.count {
            let count = outgoing.withUnsafeBytes { write(socket, $0.baseAddress!.advanced(by: offset), outgoing.count - offset) }
            if count > 0 { offset += count }
            else if count == 0 || (errno != EAGAIN && errno != EINTR) { return }
            if offset == outgoing.count { outgoing.removeAll(keepingCapacity: true); offset = 0 }
            else if offset > 65536 { outgoing.removeFirst(offset); offset = 0 }
        }
    }
    } catch {
        if !announced {
            let detail = Data(String(describing: error).utf8.prefix(2048))
            let message = try RadminRecordDecoder.encode(detail, maximumBodyLength: 2048)
            try? writeAll(socket, Array(nonce.utf8) + [0] + Array(message))
        }
        throw error
    }
}
