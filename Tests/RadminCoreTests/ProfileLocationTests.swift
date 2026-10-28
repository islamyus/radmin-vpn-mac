// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import RadminCore

@Test func freshInstallUsesApplicationSupportWithoutCreatingAnything() throws {
    let result = try ProfileLocation.resolve(home: URL(fileURLWithPath: "/fixture/home"), override: nil, directoryExists: { _ in false })
    #expect(result.path == "/fixture/home/Library/Application Support/Radmin VPN/profile")
}

@Test func existingProfileKeepsItsOriginalKeychainAccount() throws {
    let result = try ProfileLocation.resolve(home: URL(fileURLWithPath: "/fixture/home"), override: nil, directoryExists: { _ in true })
    #expect(result.path == "/fixture/home/MyHub/RadminVPN/profile")
}

@Test func explicitProfileOverridesDiscoveryAndMustBeAbsolute() throws {
    let result = try ProfileLocation.resolve(home: URL(fileURLWithPath: "/fixture/home"), override: "/fixture/custom", directoryExists: { _ in true })
    #expect(result.path == "/fixture/custom")
    #expect(throws: ProfileLocation.LocationError.self) {
        try ProfileLocation.resolve(home: URL(fileURLWithPath: "/fixture/home"), override: "relative", directoryExists: { _ in true })
    }
}
