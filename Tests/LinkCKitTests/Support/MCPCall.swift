import XCTest
@testable import LinkCKit

/// Sends one MCP `tools/call` request over `server`'s JSON-RPC pipe and decodes the first text
/// content block plus `isError`. Shared by every test file that drives an `MCPServer` directly
/// rather than through the relay — extracted from near-identical private copies in
/// `AppCoordinatorRelayTests` (`mcp`) and `MCPServerTaskTests` (`call`).
func mcpCall(_ server: MCPServer, _ name: String, _ args: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
    let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]]
    let response = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: request)))
    let result = (try JSONSerialization.jsonObject(with: response) as? [String: Any])?["result"] as? [String: Any]
    let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    return (text, result?["isError"] as? Bool ?? false)
}
