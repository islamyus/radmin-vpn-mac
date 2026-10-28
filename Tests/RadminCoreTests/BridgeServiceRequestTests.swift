// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import RadminCore

@Test func helperRequestOnlyAdmitsRadminAddressAndMatchingPrivateSocket() throws {
    let nonce = String(repeating: "a", count: 32)
    func request(_ socket: String, _ vip: String, _ token: String = nonce) throws -> BridgeServiceRequest {
        let data = try JSONSerialization.data(withJSONObject: ["socket": socket, "nonce": token, "vip": vip])
        return try JSONDecoder().decode(BridgeServiceRequest.self, from: data)
    }
    let socket = "/fixture/home/run/utun-aaaaaaaaaaaa/bridge.sock"
    #expect(try request(socket, "26.1.2.3").arguments(owner: 501).last == "501")
    for (path, ip, token) in [(socket, "1.1.1.1", nonce), ("/arbitrary.sock", "26.1.2.3", nonce),
                               (socket, "26.1.2.3", "wrong"), ("/a/../run/utun-aaaaaaaaaaaa/bridge.sock", "26.1.2.3", nonce)] {
        #expect(throws: (any Error).self) { try request(path, ip, token).arguments(owner: 501) }
    }
    #expect(throws: (any Error).self) { try request(socket, "26.1.2.3").arguments(owner: 0) }
}
