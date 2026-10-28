// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum ReconnectPolicy {
    /// Retry transport loss only for an identity already loaded in this run.
    public static func delay(attempt: Int, knownIdentity: Bool, error: String) -> TimeInterval? {
        guard knownIdentity else { return nil }
        let text = error.lowercased()
        guard !["keychain", "registration", "credential", "cancelled", "authorization", "связке", "отмен"].contains(where: text.contains) else { return nil }
        return [3, 6, 12, 24, 30][min(max(0, attempt), 4)]
    }
}
