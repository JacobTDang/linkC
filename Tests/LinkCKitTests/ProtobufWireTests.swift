import XCTest
@testable import LinkCKit

final class ProtobufWireTests: XCTestCase {
    private typealias P = ProtobufFixtures

    func testAVarintFieldDecodesItsNumberAndValue() throws {
        // 0x08 is field 1, wire type 0; 0x96 0x01 is 150 over two bytes.
        let fields = try ProtobufWire.fields(in: Data([0x08, 0x96, 0x01]))
        XCTAssertEqual(fields, [ProtobufWire.Field(number: 1, value: .varint(150))])
    }

    func testALengthDelimitedFieldCarriesItsBytes() throws {
        let fields = try ProtobufWire.fields(in: Data(P.bytesField(2, [0x61, 0x62, 0x63])))
        XCTAssertEqual(fields, [ProtobufWire.Field(number: 2, value: .bytes(Data([0x61, 0x62, 0x63])))])
    }

    func testLargeVarintsDecodeInFull() throws {
        let fields = try ProtobufWire.fields(in: Data(P.varintField(1, 205_481) + P.varintField(2, 4_294_967_296)))
        XCTAssertEqual(fields.map(\.value), [.varint(205_481), .varint(4_294_967_296)])
    }

    func testFixedWidthFieldsAreSkippedAndTheFieldsAfterThemStillRead() throws {
        let bytes = P.fixed32Field(3) + P.varintField(4, 7) + P.fixed64Field(5) + P.varintField(6, 8)
        let fields = try ProtobufWire.fields(in: Data(bytes))
        XCTAssertEqual(fields.map(\.number), [4, 6])
        XCTAssertEqual(fields.map(\.value), [.varint(7), .varint(8)])
    }

    func testARepeatedFieldKeepsEveryOccurrenceInOrder() throws {
        let bytes = P.varintField(3, 1) + P.varintField(3, 2) + P.varintField(3, 3)
        let fields = try ProtobufWire.fields(in: Data(bytes))
        XCTAssertEqual(fields.map(\.value), [.varint(1), .varint(2), .varint(3)])
    }

    func testNoBytesIsNoFields() throws {
        XCTAssertEqual(try ProtobufWire.fields(in: Data()), [])
    }

    func testAPathFindsTheFirstFieldOfANestedMessage() throws {
        let inner = P.varintField(1, 81_249) + P.bytesField(3, [0xff]) + P.varintField(4, 256_000)
        let outer = P.varintField(2, 9) + P.bytesField(1, P.varintField(1, 248) + P.bytesField(9, P.bytesField(10, inner)))
        let found = try XCTUnwrap(ProtobufWire.fields(at: [1, 9, 10], in: Data(outer)))
        XCTAssertEqual(found.varint(1), 81_249)
        XCTAssertEqual(found.varint(4), 256_000)
        XCTAssertNil(found.varint(2))
    }

    func testAPathThatLeavesTheMessageIsNil() throws {
        let outer = P.bytesField(1, P.varintField(1, 5))
        XCTAssertNil(try ProtobufWire.fields(at: [1, 9], in: Data(outer)))
    }

    func testAPathThroughANumberFieldIsNil() throws {
        XCTAssertNil(try ProtobufWire.fields(at: [1], in: Data(P.varintField(1, 5))))
    }

    func testATruncatedLengthDelimitedFieldThrowsWithTheReason() {
        // Claims 5 bytes, holds 2.
        XCTAssertThrowsError(try ProtobufWire.fields(in: Data([0x0a, 0x05, 0x61, 0x62]))) { error in
            XCTAssertTrue(error.localizedDescription.contains("ends inside"), error.localizedDescription)
        }
    }

    func testATruncatedVarintThrows() {
        XCTAssertThrowsError(try ProtobufWire.fields(in: Data([0x08, 0x96]))) { error in
            XCTAssertTrue(error.localizedDescription.contains("varint"), error.localizedDescription)
        }
    }

    func testATruncatedFixedFieldThrows() {
        XCTAssertThrowsError(try ProtobufWire.fields(in: Data([0x0d, 0x01, 0x02]))) { error in
            XCTAssertTrue(error.localizedDescription.contains("ends inside"), error.localizedDescription)
        }
    }

    func testAnUnsupportedWireTypeThrows() {
        // 0x0b is field 1, wire type 3 (a start-group).
        XCTAssertThrowsError(try ProtobufWire.fields(in: Data([0x0b]))) { error in
            XCTAssertTrue(error.localizedDescription.contains("wire type 3"), error.localizedDescription)
        }
    }

    func testFieldNumberZeroThrows() {
        XCTAssertThrowsError(try ProtobufWire.fields(in: Data([0x00, 0x01]))) { error in
            XCTAssertTrue(error.localizedDescription.contains("field number 0"), error.localizedDescription)
        }
    }
}
