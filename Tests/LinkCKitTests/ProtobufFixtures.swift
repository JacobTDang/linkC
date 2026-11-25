import Foundation

/// Builds made-up protobuf bytes for tests, the way the wire format lays them out.
enum ProtobufFixtures {
    static func varint(_ value: UInt64) -> [UInt8] {
        var rest = value
        var bytes: [UInt8] = []
        while rest >= 0x80 {
            bytes.append(UInt8(rest & 0x7f) | 0x80)
            rest >>= 7
        }
        bytes.append(UInt8(rest))
        return bytes
    }

    /// A varint field: wire type 0.
    static func varintField(_ number: Int, _ value: UInt64) -> [UInt8] {
        varint(UInt64(number) << 3) + varint(value)
    }

    /// A length-delimited field: wire type 2, a message, string or bytes.
    static func bytesField(_ number: Int, _ payload: [UInt8]) -> [UInt8] {
        varint(UInt64(number) << 3 | 2) + varint(UInt64(payload.count)) + payload
    }

    static func fixed32Field(_ number: Int) -> [UInt8] {
        varint(UInt64(number) << 3 | 5) + [1, 2, 3, 4]
    }

    static func fixed64Field(_ number: Int) -> [UInt8] {
        varint(UInt64(number) << 3 | 1) + [1, 2, 3, 4, 5, 6, 7, 8]
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
