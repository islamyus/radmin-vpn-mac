// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct PEExport: Codable, Sendable, Equatable {
    public let name: String
    public let ordinal: UInt32
    public let rva: UInt32
}
public struct PEReport: Codable, Sendable {
    public let machine: UInt16
    public let imageBase: UInt64
    public let exports: [PEExport]
    public let protocolTypes: [String]
}
public enum PEInspectionError: Error { case invalidImage, outOfBounds, unsupportedImage, unreasonableSize }

/// Static metadata reader. Never loads, links, emulates or executes the image.
public struct PEInspection {
    private let bytes: [UInt8]
    private struct Section { let rva: UInt32; let virtualSize: UInt32; let rawSize: UInt32; let rawOffset: UInt32 }
    private var sections: [Section] = []
    public init(data: Data) throws {
        guard data.count <= 128 * 1024 * 1024 else { throw PEInspectionError.unreasonableSize }
        bytes = Array(data)
    }
    private func integer(_ offset: Int, _ width: Int) throws -> UInt64 {
        guard offset >= 0, offset <= bytes.count, width <= bytes.count - offset else { throw PEInspectionError.outOfBounds }
        return (0..<width).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * $1) }
    }
    private func u16(_ offset: Int) throws -> UInt16 { UInt16(try integer(offset, 2)) }
    private func u32(_ offset: Int) throws -> UInt32 { UInt32(try integer(offset, 4)) }
    private func mapped(_ rva: UInt32, width: Int = 1) throws -> Int {
        guard width >= 0 else { throw PEInspectionError.outOfBounds }
        for section in sections where rva >= section.rva {
            let delta = UInt64(rva) - UInt64(section.rva)
            guard delta < UInt64(section.rawSize), delta + UInt64(width) <= UInt64(section.rawSize) else { continue }
            let offset = UInt64(section.rawOffset) + delta
            guard offset + UInt64(width) <= bytes.count else { throw PEInspectionError.outOfBounds }
            return Int(offset)
        }
        throw PEInspectionError.outOfBounds
    }
    private func stringAtRVA(_ rva: UInt32) throws -> String {
        var string: [UInt8] = []
        for delta in 0..<4096 {
            let value = UInt64(rva) + UInt64(delta)
            guard value <= UInt32.max else { throw PEInspectionError.outOfBounds }
            let byte = bytes[try mapped(UInt32(value))]
            if byte == 0 { return String(decoding: string, as: UTF8.self) }
            string.append(byte)
        }
        throw PEInspectionError.unreasonableSize
    }
    public mutating func report() throws -> PEReport {
        guard try u16(0) == 0x5a4d else { throw PEInspectionError.invalidImage }
        let pe = Int(try u32(0x3c))
        guard try u32(pe) == 0x4550 else { throw PEInspectionError.invalidImage }
        let machine = try u16(pe + 4)
        let count = Int(try u16(pe + 6))
        let optionalSize = Int(try u16(pe + 20))
        guard count <= 96, optionalSize >= 96 else { throw PEInspectionError.unreasonableSize }
        let optional = pe + 24
        let magic = try u16(optional)
        let directories: Int, imageBase: UInt64, directoryCountOffset: Int
        switch magic {
        case 0x10b:
            directories = optional + 96; imageBase = UInt64(try u32(optional + 28)); directoryCountOffset = optional + 92
        case 0x20b:
            guard optionalSize >= 112 else { throw PEInspectionError.invalidImage }
            directories = optional + 112; imageBase = try integer(optional + 24, 8); directoryCountOffset = optional + 108
        default: throw PEInspectionError.unsupportedImage
        }
        let table = optional + optionalSize
        sections = try (0..<count).map { index in
            let offset = table + index * 40
            return Section(rva: try u32(offset + 12), virtualSize: try u32(offset + 8),
                           rawSize: try u32(offset + 16), rawOffset: try u32(offset + 20))
        }
        var exports: [PEExport] = []
        let directoryCount = try u32(directoryCountOffset)
        if directoryCount > 0 {
            guard directories + 8 <= optional + optionalSize else { throw PEInspectionError.invalidImage }
            let exportRVA = try u32(directories)
            if exportRVA != 0 {
                let export = try mapped(exportRVA, width: 40)
                let ordinalBase = try u32(export + 16)
                let functionCount = try u32(export + 20)
                let nameCount = try u32(export + 24)
                guard nameCount <= 100_000, functionCount <= 100_000 else { throw PEInspectionError.unreasonableSize }
                if nameCount > 0 {
                    let functions = try mapped(u32(export + 28), width: Int(functionCount) * 4)
                    let names = try mapped(u32(export + 32), width: Int(nameCount) * 4)
                    let ordinals = try mapped(u32(export + 36), width: Int(nameCount) * 2)
                    for index in 0..<Int(nameCount) {
                        let ordinalIndex = UInt32(try u16(ordinals + index * 2))
                        guard ordinalIndex < functionCount,
                              UInt64(ordinalBase) + UInt64(ordinalIndex) <= UInt32.max else { throw PEInspectionError.invalidImage }
                        exports.append(PEExport(name: try stringAtRVA(u32(names + index * 4)),
                            ordinal: ordinalBase + ordinalIndex,
                            rva: try u32(functions + Int(ordinalIndex) * 4)))
                    }
                }
            }
        }
        var types = Set<String>()
        var start = 0
        for index in 0...bytes.count {
            let isASCII = index < bytes.count && bytes[index] >= 32 && bytes[index] < 127
            if isASCII { continue }
            if index - start >= 6, index - start <= 4096 {
                let text = String(decoding: bytes[start..<index], as: UTF8.self)
                if text.hasPrefix(".?AV"), text.contains("RolClient@@") || text.contains("ControlSvc@@") {
                    types.insert(text)
                }
            }
            start = index + 1
        }
        return PEReport(machine: machine, imageBase: imageBase, exports: exports, protocolTypes: types.sorted())
    }
}
