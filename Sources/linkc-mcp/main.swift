import Foundation
import LinkCKit

let args = CommandLine.arguments

if args.contains("--install") || args.contains("install") {
    let binaryPath = args.count > 2 ? args[2] : MCPRegistrar.defaultBinaryPath()
    do {
        try MCPRegistrar.registerAll(binaryPath: binaryPath)
        FileHandle.standardError.write(Data("✓ linkc-multiplier MCP registered across Claude, Cursor, Codex, and Antigravity\n".utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Error registering MCP server: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if args.contains("--help") || args.contains("-h") {
    let help = """
    linkc-mcp — Universal Multi-Agent Shared Context MCP Server

    Usage:
      linkc-mcp            Run stdio MCP server for current working directory
      linkc-mcp --install  Register server with Claude, Cursor, Codex, and Antigravity

    """
    FileHandle.standardError.write(Data(help.utf8))
    exit(0)
}

let cwd = FileManager.default.currentDirectoryPath
let server = MCPServer(workspaceRoot: cwd)

// MCP stdio server loop: reads lines or Content-Length headers from stdin
let stdin = FileHandle.standardInput
let stdout = FileHandle.standardOutput

var readBuffer = Data()

while true {
    let chunk = stdin.availableData
    if chunk.isEmpty {
        break // EOF reached
    }
    readBuffer.append(chunk)

    while let newlineRange = readBuffer.range(of: Data([0x0A])) { // '\n'
        let lineData = readBuffer.subdata(in: 0..<newlineRange.lowerBound)
        readBuffer.removeSubrange(0..<newlineRange.upperBound)

        // Ignore empty lines
        if lineData.isEmpty {
            continue
        }

        // Skip HTTP-style header frames if present
        if let lineStr = String(data: lineData, encoding: .utf8),
           lineStr.lowercased().hasPrefix("content-length:") {
            continue
        }

        // Process line as JSON message
        if let responseData = server.handleMessage(lineData) {
            stdout.write(responseData)
            stdout.write(Data([0x0A])) // \n
        }
    }
}
