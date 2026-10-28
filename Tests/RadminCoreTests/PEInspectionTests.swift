// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import RadminCore

func peFixture() -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 1024)
    func put(_ offset: Int, _ value: UInt32, width: Int = 4) {
        for index in 0..<width { bytes[offset + index] = UInt8((value >> (index * 8)) & 255) }
    }
    put(0, 0x5a4d, width: 2); put(0x3c, 0x80); put(0x80, 0x4550)
    put(0x84, 0x14c, width: 2); put(0x86, 1, width: 2); put(0x94, 224, width: 2)
    put(0x98, 0x10b, width: 2); put(0x98 + 28, 0x10000000)
    put(0x98 + 92, 16); put(0x98 + 96, 0x1000); put(0x98 + 100, 128)
    put(0x178 + 8, 512); put(0x178 + 12, 0x1000)
    put(0x178 + 16, 512); put(0x178 + 20, 512)
    put(0x200 + 16, 1); put(0x200 + 20, 1); put(0x200 + 24, 1)
    put(0x200 + 28, 0x1040); put(0x200 + 32, 0x1044); put(0x200 + 36, 0x1048)
    put(0x240, 0x1100); put(0x244, 0x1050); put(0x248, 0, width: 2)
    let name = Array("ROLClient_Register\0".utf8)
    bytes.replaceSubrange(0x250..<(0x250 + name.count), with: name)
    return bytes
}

@Test func staticPEExportsReadWithoutLoadingCode() throws {
    var inspection = try PEInspection(data: Data(peFixture()))
    let report = try inspection.report()
    #expect(report.machine == 0x14c)
    #expect(report.imageBase == 0x10000000)
    #expect(report.exports == [PEExport(name: "ROLClient_Register", ordinal: 1, rva: 0x1100)])
}

@Test func truncatedPEInputsFailSafely() throws {
    let fixture = peFixture()
    for size in [0, 2, 60, 64, 128, 248, 376, 512, 550, 592] {
        var inspection = try PEInspection(data: Data(fixture.prefix(size)))
        #expect(throws: PEInspectionError.self) { try inspection.report() }
    }
}

@Test func invalidOrdinalCannotIndexOutsideFunctionTable() throws {
    var fixture = peFixture(); fixture[0x248] = 2
    var inspection = try PEInspection(data: Data(fixture))
    #expect(throws: PEInspectionError.self) { try inspection.report() }
}

@Test func unreasonableExportCountRejected() throws {
    var fixture = peFixture()
    fixture.replaceSubrange(0x218..<0x21c, with: [255, 255, 255, 255])
    var inspection = try PEInspection(data: Data(fixture))
    #expect(throws: PEInspectionError.self) { try inspection.report() }
}

@Test func asciiProtocolTypeInventory() throws {
    var fixture = peFixture()
    let type = ".?AVCRosProtocol_SRP_Register@RolClient@@"
    let string = Array((type + "\0").utf8)
    fixture.replaceSubrange(0x300..<(0x300 + string.count), with: string)
    var inspection = try PEInspection(data: Data(fixture))
    #expect(try inspection.report().protocolTypes == [type])
}
