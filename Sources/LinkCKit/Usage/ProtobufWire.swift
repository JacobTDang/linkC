import Foundation

/// The smallest reader of protobuf's wire format that lets linkC pick numbers out of an agent's
/// records, which are protobuf messages with no schema to hand: varint and length-delimited fields
/// are kept, fixed32 and fixed64 are skipped over. Malformed bytes throw rather than read as less.
public enum ProtobufWire {
    public enum Value: Equatable, Sendable {
        case varint(UInt64)
        /// A length-delimited field: a nested message, a string or raw bytes.
        case bytes(Data)
    }

    public struct Field: Equatable, Sendable {
        public let number: Int
        public let value: Value
    }

    /// Every varint and length-delimited field of the message in `data`, in the order written.
    public static func fields(in data: Data) throws -> [Field] {
        let bytes = [UInt8](data)
        var fields: [Field] = []
        var position = 0
        while position < bytes.count {
            let tag = try readVarint(bytes, &position)
            let number = Int(truncatingIfNeeded: tag >> 3)
            guard number > 0 else { throw LinkCError.parse("protobuf has field number 0 at byte \(position)") }
            switch tag & 7 {
            case 0:
                fields.append(Field(number: number, value: .varint(try readVarint(bytes, &position))))
            case 1:
                try skip(8, in: bytes, &position)
            case 2:
                let length = try readVarint(bytes, &position)
                guard length <= UInt64(bytes.count - position) else {
                    throw LinkCError.parse("protobuf field \(number) ends inside its \(length) bytes at byte \(position)")
                }
                let end = position + Int(length)
                fields.append(Field(number: number, value: .bytes(Data(bytes[position..<end]))))
                position = end
            case 5:
                try skip(4, in: bytes, &position)
            case let wireType:
                throw LinkCError.parse("protobuf field \(number) has wire type \(wireType), which this reader does not decode")
            }
        }
        return fields
    }

    /// The fields of the message reached by following `path`, a field number per level, into the
    /// first length-delimited field with each number. Nil when a level is absent or is not a message.
    public static func fields(at path: [Int], in data: Data) throws -> [Field]? {
        var current = try fields(in: data)
        for number in path {
            guard let next = current.message(number) else { return nil }
            current = try fields(in: next)
        }
        return current
    }

    private static func readVarint(_ bytes: [UInt8], _ position: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 7) {
            guard position < bytes.count else { throw LinkCError.parse("protobuf varint ends inside its bytes at byte \(position)") }
            let byte = bytes[position]
            position += 1
            result |= UInt64(byte & 0x7f) << UInt64(shift)
            if byte & 0x80 == 0 { return result }
        }
        throw LinkCError.parse("protobuf varint runs past ten bytes at byte \(position)")
    }

    private static func skip(_ count: Int, in bytes: [UInt8], _ position: inout Int) throws {
        guard count <= bytes.count - position else {
            throw LinkCError.parse("protobuf fixed-width field ends inside its \(count) bytes at byte \(position)")
        }
        position += count
    }
}

extension Array where Element == ProtobufWire.Field {
    /// The first varint field numbered `number`.
    public func varint(_ number: Int) -> UInt64? {
        for field in self where field.number == number {
            if case .varint(let value) = field.value { return value }
        }
        return nil
    }

    /// The first length-delimited field numbered `number`.
    public func message(_ number: Int) -> Data? {
        for field in self where field.number == number {
            if case .bytes(let data) = field.value { return data }
        }
        return nil
    }
}
