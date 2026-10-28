// SPDX-License-Identifier: GPL-3.0-only
import CUtun
import Darwin
import Foundation
import RadminCore

private func exact(_ socket: Int32, _ count: Int, deadline: TimeInterval) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count), offset = 0
    while offset < count {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw CocoaError(.fileReadCorruptFile) }
        var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, Int32(min(3000, max(1, remaining * 1000))))
        if ready < 0 && errno == EINTR { continue }
        guard ready > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let n = bytes.withUnsafeMutableBytes { read(socket, $0.baseAddress!.advanced(by: offset), count - offset) }
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw CocoaError(.fileReadCorruptFile) }
        offset += n
    }
    return Data(bytes)
}

/// One permitted UID, one active adapter, no executable paths or shell commands
/// accepted over IPC. Interface lifetime remains tied to the engine connection.
func serveDaemon(_ arguments: [String]) throws {
    guard geteuid() == 0, arguments.count == 2, arguments[0] == "--owner",
          let owner = UInt32(arguments[1]), owner > 0 else { throw CocoaError(.fileReadNoPermission) }
    let listener = rvpn_listen_service(owner)
    guard listener >= 0 else { throw CocoaError(.fileWriteNoPermission) }
    defer { close(listener) }
    let available = DispatchSemaphore(value: 1)
    while true {
        let socket = rvpn_accept_service(listener, owner)
        if socket < 0 {
            if errno == EINTR || errno == EPERM { continue }
            throw CocoaError(.fileReadUnknown)
        }
        do {
            defer { close(socket) }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            let header = Array(try exact(socket, 8, deadline: deadline))
            guard Array(header[0..<4]) == Array("RVS1".utf8) else { throw CocoaError(.fileReadCorruptFile) }
            let size = header[4...7].reduce(0) { ($0 << 8) | Int($1) }
            guard (1...2048).contains(size) else { throw CocoaError(.fileReadCorruptFile) }
            let request = try JSONDecoder().decode(BridgeServiceRequest.self, from: exact(socket, size, deadline: deadline))
            let command = try request.arguments(owner: owner)
            guard available.wait(timeout: .now()) == .success else {
                var busy: UInt8 = 1; _ = write(socket, &busy, 1); continue
            }
            var accepted: UInt8 = 0
            guard write(socket, &accepted, 1) == 1 else { available.signal(); continue }
            DispatchQueue.global(qos: .userInitiated).async {
                defer { available.signal() }
                do { try serveInterface(command) }
                catch { FileHandle.standardError.write(Data("Radmin adapter session ended with an error.\n".utf8)) }
            }
        } catch {
            // Invalid or incomplete requests cannot terminate the root daemon.
        }
    }
}
