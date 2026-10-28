// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum ProfileLocation {
    public enum LocationError: Error { case invalidOverride }

    /// Preserve the original account path: changing it would select a different
    /// Keychain identity. Fresh installations use the normal macOS data folder.
    public static func resolve(home: URL, override: String?, directoryExists: (URL) -> Bool) throws -> URL {
        if let override {
            guard override.hasPrefix("/"), !override.utf8.contains(0) else { throw LocationError.invalidOverride }
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        let legacy = home.appendingPathComponent("MyHub/RadminVPN/profile", isDirectory: true)
        if directoryExists(legacy) { return legacy }
        return home.appendingPathComponent("Library/Application Support/Radmin VPN/profile", isDirectory: true)
    }
}
