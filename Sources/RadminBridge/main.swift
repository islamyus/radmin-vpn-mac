// SPDX-License-Identifier: GPL-3.0-only
import CUtun
import Darwin
import Foundation

if CommandLine.arguments.dropFirst().first == "--daemon" {
    do { try serveDaemon(Array(CommandLine.arguments.dropFirst(2))); exit(0) }
    catch { FileHandle.standardError.write(Data("Radmin adapter service failed.\n".utf8)); exit(1) }
}

// Native interface diagnostic. No Windows runtime, proprietary DLLs, routes,
// driver emulation or server traffic. The interface closes immediately.
if CommandLine.arguments.dropFirst().first == "--serve" {
    do { try serveInterface(Array(CommandLine.arguments.dropFirst(2))); exit(0) }
    catch {
        FileHandle.standardError.write(Data("Native interface setup failed: \(error)\n".utf8))
        exit(1)
    }
}
guard CommandLine.arguments == [CommandLine.arguments[0], "--probe"] else {
    FileHandle.standardError.write(Data("Usage: radmin-bridge --probe\n".utf8)); exit(2)
}
var name = [CChar](repeating: 0, count: 64)
let fd = rvpn_open_utun(&name, name.count)
guard fd >= 0 else {
    FileHandle.standardError.write(Data("utun: \(String(cString: strerror(errno))). Administrator access is required.\n".utf8))
    exit(1)
}
let interface = String(decoding: name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
close(fd)
print("Created and closed native interface: \(interface)")
