// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import RadminCore

private func hex(_ text: String) -> Data {
    let characters = Array(text.filter { !$0.isWhitespace })
    return Data(stride(from: 0, to: characters.count, by: 2).map {
        UInt8(String(characters[$0...($0 + 1)]), radix: 16)!
    })
}

// Captured constant header, corroborated by SHelper_GetNetworkProtocolVersion
// and SHelper_CheckNetworkProtocolVersion in the matching reference binary.
private let versionRecord = hex("00000004 03000000")

// Actual plaintext response structure from capture 20261017-175709.
// Only the echoed eight-byte client value is zeroed; no user network IDs,
// passwords, client address or cryptographic session material is committed.
private let lookupRecord = hex("""
00000062
00000004 01000320 0000000a
0000004e 00001234
00000004 0100025b 00000011
0000001e 030001c9 00350037002e003100320038002e003100380037002e0031003800380001
00000008 0200024d 0000000000000000
00000004 010001cf 00000001
""")

@Test func observedVersionHeaderIsExactlyReproduced() throws {
    #expect(try RadminRecordDecoder.encode(hex("03000000")) == versionRecord)
    var decoder = RadminRecordDecoder()
    #expect(try decoder.append(versionRecord) == [hex("03000000")])
}

@Test func realLookupRecordHandlesEveryTCPSplit() throws {
    for split in 0...lookupRecord.count {
        var decoder = RadminRecordDecoder()
        let first = try decoder.append(Data(lookupRecord.prefix(split)))
        let second = try decoder.append(Data(lookupRecord.dropFirst(split)))
        #expect(first + second == [Data(lookupRecord.dropFirst(4))])
        #expect(decoder.pendingByteCount == 0)
    }
}

@Test func captureSegmentBoundaryInsideLargeRecord() throws {
    // Server record is 2576 bytes, carried as 1460 + 1120 TCP payload bytes.
    // The opaque body is synthetic: authentication ciphertext stays private.
    let body = Data(repeating: 0xA5, count: 2576)
    let record = try RadminRecordDecoder.encode(body)
    var decoder = RadminRecordDecoder()
    #expect(try decoder.append(Data(record.prefix(1460))).isEmpty)
    #expect(try decoder.append(Data(record.dropFirst(1460))) == [body])
}

@Test func multipleRecordsInOneReadArePreserved() throws {
    var decoder = RadminRecordDecoder()
    let expected = [hex("03000000"), Data(lookupRecord.dropFirst(4)), hex("03000000")]
    #expect(try decoder.append(versionRecord + lookupRecord + versionRecord) == expected)
}

@Test func interfaceBurstWithPartialMTURecordStaysWithinBudget() throws {
    let frames = (0..<12).map { Data(repeating: UInt8($0), count: 1514) }
    let wire = try frames.reduce(into: Data()) { $0.append(try RadminRecordDecoder.encode($1, maximumBodyLength: 1514)) }
    // The old helper could accumulate 1517 pending bytes, then read 2048:
    // that exceeds the decoder's 3036-byte budget and tears down the utun.
    var oldReader = RadminRecordDecoder(maximumBodyLength: 1514)
    #expect(try oldReader.append(Data(wire.prefix(1517))).isEmpty)
    #expect(throws: RadminWireError.bufferLimit) { try oldReader.append(Data(wire[1517..<(1517 + 2048)])) }
    for split in [1, 3, 511, 1024, 1517] {
        var decoder = RadminRecordDecoder(maximumBodyLength: 1514)
        var decoded = try decoder.append(Data(wire.prefix(split)))
        var offset = split
        while offset < wire.count {
            let end = min(wire.count, offset + decoder.maximumReadLength)
            decoded += try decoder.append(Data(wire[offset..<end]))
            offset = end
        }
        #expect(decoded == frames)
        #expect(decoder.pendingByteCount == 0)
    }
}

@Test func observedPlaintextTLVRoundTripAndNestedContainer() throws {
    let body = Data(lookupRecord.dropFirst(4))
    let outer = try RadminTLV.decode(body)
    #expect(outer.map(\.tag) == [0x01000320, 0x00001234])
    #expect(outer.map { $0.value.count } == [4, 78])
    #expect(try RadminTLV.encode(outer) == body)
    let inner = try RadminTLV.decode(outer[1].value)
    #expect(inner.map(\.tag) == [0x0100025b, 0x030001c9, 0x0200024d, 0x010001cf])
    #expect(inner.map { $0.value.count } == [4, 30, 8, 4])
    #expect(try RadminTLV.encode(inner) == outer[1].value)
}

@Test func oversizedHeaderFailsClosedUntilReset() throws {
    var decoder = RadminRecordDecoder(maximumBodyLength: 1024)
    #expect(throws: RadminWireError.recordTooLarge) { try decoder.append(hex("ffffffff")) }
    #expect(throws: RadminWireError.failedDecoder) { try decoder.append(versionRecord) }
    decoder.reset()
    #expect(try decoder.append(versionRecord) == [hex("03000000")])
    #expect(throws: RadminWireError.bufferLimit) { try decoder.append(Data(repeating: 0, count: 2057)) }
}

@Test func truncatedTLVAndFieldFloodRejected() throws {
    #expect(throws: RadminWireError.truncatedField) { try RadminTLV.decode(hex("00000004 01000320 00")) }
    #expect(throws: RadminWireError.truncatedField) { try RadminTLV.decode(hex("00000004")) }
    #expect(throws: RadminWireError.fieldLimit) { try RadminTLV.decode(Data(lookupRecord.dropFirst(4)), maximumFieldCount: 1) }
    #expect(throws: RadminWireError.recordTooLarge) { try RadminTLV.decode(hex("ffffffff 01000320")) }
}

@Test func unknownTagsAndEmptyValuesRemainOpaque() throws {
    let fields = [RadminTLVField(tag: 0x7f001234, value: Data()), RadminTLVField(tag: 0x7f001234, value: hex("ff00"))]
    #expect(try RadminTLV.decode(RadminTLV.encode(fields)) == fields)
}
