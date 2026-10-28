// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Darwin
import Foundation

enum BridgeServiceInstaller {
    static var installed: Bool { FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/dev.radminvpn.mac.bridge.plist") }
    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func install() async throws -> String {
        guard let directory = Bundle.main.executableURL?.deletingLastPathComponent(),
              let script = Bundle.main.url(forResource: "install-bridge-service", withExtension: "sh"),
              let manifest = Bundle.main.url(forResource: "bridge", withExtension: "sha256") else { throw CocoaError(.fileNoSuchFile) }
        let helper = directory.appendingPathComponent("radmin-bridge")
        let digest = try String(contentsOf: manifest, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let actual = SHA256.hash(data: try Data(contentsOf: helper)).map { String(format: "%02x", $0) }.joined()
        guard actual == digest else { throw CocoaError(.fileReadCorruptFile) }
        let arguments = ["/bin/zsh", script.path, "--install", helper.path, digest, String(getuid())]
        let command = arguments.map(shellQuote).joined(separator: " ")
        let appleString = "\"" + command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        return try await Task.detached {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \(appleString) with administrator privileges"]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "RadminBridgeInstall", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: data.prefix(2048), as: UTF8.self)])
            }
            return "Служба адаптера установлена. Подключения больше не требуют пароля администратора для адаптера."
        }.value
    }
}
