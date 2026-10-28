// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import RadminCore

struct RecordShape: Encodable {
    let bodyLength: Int
    let isObservedVersion3: Bool
    let structurallyValidTLV: [TLVShape]?
}
struct TLVShape: Encodable { let tagHex: String; let valueLength: Int }
struct StreamReport: Encodable { let records: [RecordShape]; let pendingBytes: Int }

do {
    guard CommandLine.arguments.count == 3 else {
        FileHandle.standardError.write(Data("Usage: radmin-research inspect FILE.dll | records TCP_STREAM.bin\nOffline analysis only; no Windows code is executed.\n".utf8))
        exit(2)
    }
    let url = URL(fileURLWithPath: CommandLine.arguments[2])
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    switch CommandLine.arguments[1] {
    case "inspect":
        var inspection = try PEInspection(data: Data(contentsOf: url))
        FileHandle.standardOutput.write(try encoder.encode(inspection.report()))
    case "records":
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var decoder = RadminRecordDecoder()
        var records: [RecordShape] = []
        var total = 0
        while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
            total += chunk.count
            guard total <= 16 * 1024 * 1024 else { throw RadminWireError.bufferLimit }
            for body in try decoder.append(chunk) {
                let fields = try? RadminTLV.decode(body)
                records.append(RecordShape(bodyLength: body.count, isObservedVersion3: body == Data([3, 0, 0, 0]),
                    structurallyValidTLV: fields?.map { TLVShape(tagHex: String(format: "%08X", $0.tag), valueLength: $0.value.count) }))
            }
        }
        FileHandle.standardOutput.write(try encoder.encode(StreamReport(records: records, pendingBytes: decoder.pendingByteCount)))
    default:
        FileHandle.standardError.write(Data("Unknown operation; use inspect or records.\n".utf8)); exit(2)
    }
    print("")
} catch {
    FileHandle.standardError.write(Data("Offline analysis failed: \(error)\n".utf8)); exit(1)
}
