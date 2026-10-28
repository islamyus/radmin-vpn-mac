// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum RadminWireError: Error, Equatable {
    case recordTooLarge, bufferLimit, failedDecoder, truncatedField, fieldLimit
}

/// Observed on two complete control connections in capture 20261017-175709:
/// u32 big-endian body length, followed by exactly that many opaque bytes.
/// This does not decrypt or authenticate a record. Limits are local policy,
/// not a claim about an undocumented server-side maximum.
public struct RadminRecordDecoder: Sendable {
    public let maximumBodyLength: UInt32
    private var buffer: [UInt8] = []
    private var failed = false
    public init(maximumBodyLength: UInt32 = 1_048_576) { self.maximumBodyLength = maximumBodyLength }

    public mutating func append(_ input: Data) throws -> [Data] {
        guard !failed else { throw RadminWireError.failedDecoder }
        guard UInt64(buffer.count) + UInt64(input.count) <= UInt64(maximumBodyLength) * 2 + 8 else {
            failed = true; throw RadminWireError.bufferLimit
        }
        buffer.append(contentsOf: input)
        var offset = 0
        var records: [Data] = []
        while buffer.count - offset >= 4 {
            let size = UInt32(buffer[offset]) << 24 | UInt32(buffer[offset + 1]) << 16
                | UInt32(buffer[offset + 2]) << 8 | UInt32(buffer[offset + 3])
            guard size <= maximumBodyLength else { failed = true; throw RadminWireError.recordTooLarge }
            guard UInt64(buffer.count - offset - 4) >= UInt64(size) else { break }
            let end = offset + 4 + Int(size)
            records.append(Data(buffer[(offset + 4)..<end])); offset = end
        }
        if offset > 0 { buffer.removeFirst(offset) }
        return records
    }

    public var pendingByteCount: Int { buffer.count }
    /// A caller reading a stream should bound each read to one maximum record.
    /// An incomplete record plus this chunk always fits the decoder's budget.
    public var maximumReadLength: Int { Int(maximumBodyLength) + 4 }
    public mutating func reset() { buffer.removeAll(keepingCapacity: false); failed = false }

    public static func encode(_ body: Data, maximumBodyLength: UInt32 = 1_048_576) throws -> Data {
        guard UInt64(body.count) <= UInt64(maximumBodyLength) else { throw RadminWireError.recordTooLarge }
        let length = UInt32(body.count)
        var data = Data([UInt8(length >> 24), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
        data.append(body); return data
    }
}

public struct RadminTLVField: Sendable, Equatable {
    public let tag: UInt32
    public let value: Data
    public init(tag: UInt32, value: Data) { self.tag = tag; self.value = value }
}

/// Observed plaintext lookup response: u32 BE value length, u32 BE tag, value.
/// Tags and values are deliberately opaque. Encrypted authentication records
/// must never be passed off as plaintext TLV or as authenticated network state.
public enum RadminTLV {
    public static func decode(_ data: Data, maximumFieldLength: UInt32 = 1_048_576,
                              maximumFieldCount: Int = 1024) throws -> [RadminTLVField] {
        let bytes = [UInt8](data)
        var offset = 0
        var fields: [RadminTLVField] = []
        while offset < bytes.count {
            guard fields.count < maximumFieldCount else { throw RadminWireError.fieldLimit }
            guard bytes.count - offset >= 8 else { throw RadminWireError.truncatedField }
            let length = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
            let tag = UInt32(bytes[offset + 4]) << 24 | UInt32(bytes[offset + 5]) << 16
                | UInt32(bytes[offset + 6]) << 8 | UInt32(bytes[offset + 7])
            guard length <= maximumFieldLength else { throw RadminWireError.recordTooLarge }
            guard UInt64(length) <= UInt64(bytes.count - offset - 8) else { throw RadminWireError.truncatedField }
            let end = offset + 8 + Int(length)
            fields.append(RadminTLVField(tag: tag, value: Data(bytes[(offset + 8)..<end])))
            offset = end
        }
        return fields
    }

    public static func encode(_ fields: [RadminTLVField], maximumFieldLength: UInt32 = 1_048_576,
                              maximumFieldCount: Int = 1024) throws -> Data {
        guard fields.count <= maximumFieldCount else { throw RadminWireError.fieldLimit }
        var result = Data()
        for field in fields {
            guard UInt64(field.value.count) <= UInt64(maximumFieldLength) else { throw RadminWireError.recordTooLarge }
            let length = UInt32(field.value.count)
            result.append(contentsOf: [UInt8(length >> 24), UInt8((length >> 16) & 255),
                                      UInt8((length >> 8) & 255), UInt8(length & 255)])
            result.append(contentsOf: [UInt8(field.tag >> 24), UInt8((field.tag >> 16) & 255),
                                      UInt8((field.tag >> 8) & 255), UInt8(field.tag & 255)])
            result.append(field.value)
        }
        return result
    }
}
