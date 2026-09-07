import XCTest
@testable import LinkCKit

final class MCPProtocolTests: XCTestCase {

    func testJSONValuePrimitivesRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Null
        let nullVal = JSONValue.null
        let nullData = try encoder.encode(nullVal)
        let decodedNull = try decoder.decode(JSONValue.self, from: nullData)
        XCTAssertEqual(decodedNull, .null)

        // Bool
        let boolVal = JSONValue.bool(true)
        let boolData = try encoder.encode(boolVal)
        let decodedBool = try decoder.decode(JSONValue.self, from: boolData)
        XCTAssertEqual(decodedBool, .bool(true))

        // Int
        let intVal = JSONValue.int(42)
        let intData = try encoder.encode(intVal)
        let decodedInt = try decoder.decode(JSONValue.self, from: intData)
        XCTAssertEqual(decodedInt, .int(42))

        // Double
        let doubleVal = JSONValue.double(3.1415)
        let doubleData = try encoder.encode(doubleVal)
        let decodedDouble = try decoder.decode(JSONValue.self, from: doubleData)
        XCTAssertEqual(decodedDouble, .double(3.1415))

        // String
        let stringVal = JSONValue.string("hello linkc")
        let stringData = try encoder.encode(stringVal)
        let decodedString = try decoder.decode(JSONValue.self, from: stringData)
        XCTAssertEqual(decodedString, .string("hello linkc"))
    }

    func testJSONValueCollectionsRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Array
        let arrayVal = JSONValue.array([.int(1), .string("two"), .bool(false), .null])
        let arrayData = try encoder.encode(arrayVal)
        let decodedArray = try decoder.decode(JSONValue.self, from: arrayData)
        XCTAssertEqual(decodedArray, arrayVal)

        // Object
        let objectVal = JSONValue.object([
            "key": .string("value"),
            "count": .int(10),
            "nested": .array([.bool(true)])
        ])
        let objectData = try encoder.encode(objectVal)
        let decodedObject = try decoder.decode(JSONValue.self, from: objectData)
        XCTAssertEqual(decodedObject, objectVal)
    }

    func testMCPMessageRequestAndResponseRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Request
        let req = MCPMessage(
            jsonrpc: "2.0",
            id: .int(1),
            method: "tools/call",
            params: .object(["name": .string("linkc_check_conflicts")])
        )
        let reqData = try encoder.encode(req)
        let decodedReq = try decoder.decode(MCPMessage.self, from: reqData)
        XCTAssertEqual(decodedReq.jsonrpc, "2.0")
        XCTAssertEqual(decodedReq.id, .int(1))
        XCTAssertEqual(decodedReq.method, "tools/call")

        // Response with result
        let res = MCPMessage(
            jsonrpc: "2.0",
            id: .int(1),
            result: .object(["conflicts": .array([])])
        )
        let resData = try encoder.encode(res)
        let decodedRes = try decoder.decode(MCPMessage.self, from: resData)
        XCTAssertEqual(decodedRes.jsonrpc, "2.0")
        XCTAssertEqual(decodedRes.id, .int(1))
        XCTAssertEqual(decodedRes.result, .object(["conflicts": .array([])]))

        // Response with error
        let errPayload = MCPErrorPayload(code: -32601, message: "Method not found", data: .string("extra details"))
        let errRes = MCPMessage(
            jsonrpc: "2.0",
            id: .int(2),
            error: errPayload
        )
        let errData = try encoder.encode(errRes)
        let decodedErr = try decoder.decode(MCPMessage.self, from: errData)
        XCTAssertEqual(decodedErr.jsonrpc, "2.0")
        XCTAssertEqual(decodedErr.error?.code, -32601)
        XCTAssertEqual(decodedErr.error?.message, "Method not found")
        XCTAssertEqual(decodedErr.error?.data, .string("extra details"))
    }
}
