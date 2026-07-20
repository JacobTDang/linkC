import Foundation
import Network

/// Local loopback HTTP server that receives Claude Code HTTP hooks.
/// Responds 200 with an empty JSON body immediately and never blocks a turn.
///
/// Binds `127.0.0.1` ONLY (never `0.0.0.0`/`::`) via `NWParameters.requiredLocalEndpoint`.
/// Accepted connections are driven on a single dedicated serial queue. `start()`/`stop()`
/// and the `port` getter may be called from whatever thread owns this server, so the two
/// pieces of state they touch (`listener`, `_resolvedPort`) are guarded by `stateLock`.
public final class HookServer: @unchecked Sendable {
    private let requestedPort: UInt16
    private let queue = DispatchQueue(label: "com.linkc.hookserver")
    private let stateLock = NSLock()
    private var _resolvedPort: UInt16
    private var listener: NWListener?

    /// Called on each decoded event. The caller is responsible for hopping to the main actor.
    /// Invoked on the server's internal queue — keep it fast; it runs before the response
    /// is sent, but the response path itself does no other work regardless.
    public var onEvent: (@Sendable (HookEvent) -> Void)?

    public init(port: UInt16) {
        self.requestedPort = port
        self._resolvedPort = port
    }

    /// The bound port. Equal to the requested port, except when constructed with `0`
    /// (ephemeral), in which case this reflects the OS-assigned port once `start()` returns.
    public var port: UInt16 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _resolvedPort
    }

    /// Binds and starts listening. Synchronous: by the time this returns, either the
    /// listener is `.ready` (and `.port` reflects the real bound port) or it has thrown.
    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: Self.wirePort(requestedPort))

        let newListener: NWListener
        do {
            newListener = try NWListener(using: params)
        } catch {
            throw LinkCError.server("failed to create hook listener: \(error)")
        }

        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        let semaphore = DispatchSemaphore(value: 0)
        let outcomeLock = NSLock()
        var outcome: Result<Void, Error>?

        newListener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .waiting:
                outcomeLock.lock()
                let alreadyResolved = outcome != nil
                if !alreadyResolved {
                    switch state {
                    case .ready: outcome = .success(())
                    case .failed(let error): outcome = .failure(error)
                    case .waiting(let error): outcome = .failure(error)
                    default: break
                    }
                }
                outcomeLock.unlock()
                if !alreadyResolved { semaphore.signal() }
            default:
                break
            }
        }

        newListener.start(queue: queue)
        semaphore.wait()

        outcomeLock.lock()
        let resolvedOutcome = outcome
        outcomeLock.unlock()

        switch resolvedOutcome {
        case .success:
            stateLock.lock()
            _resolvedPort = newListener.port?.rawValue ?? requestedPort
            listener = newListener
            stateLock.unlock()
        case .failure(let error):
            newListener.cancel()
            throw LinkCError.server("hook listener failed to start on 127.0.0.1:\(requestedPort): \(error)")
        case nil:
            newListener.cancel()
            throw LinkCError.server("hook listener did not report a state before start() returned")
        }
    }

    /// Cancels the listener. Idempotent; safe to call even if `start()` was never called
    /// or already failed.
    public func stop() {
        stateLock.lock()
        let current = listener
        listener = nil
        stateLock.unlock()
        current?.cancel()
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffered: Data())
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var buffer = buffered
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            if let request = Self.parseRequest(buffer) {
                self.respond(on: connection, request: request)
                return
            }

            guard error == nil, !isComplete else {
                connection.cancel()
                return
            }

            self.receive(on: connection, buffered: buffer)
        }
    }

    /// Decode (if recognized) then ALWAYS respond 200 `{}` immediately — no other work on
    /// this path. Never withholds or delays the response for an unrecognized event, and
    /// never returns anything but success: this must never be able to deny a Claude tool.
    private func respond(on connection: NWConnection, request: ParsedRequest) {
        if let event = HookEventDecoder.decode(headers: request.headers, body: request.body) {
            onEvent?(event)
        }

        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Minimal HTTP/1.1 request parsing

    private struct ParsedRequest {
        let headers: [String: String]
        let body: Data
    }

    /// Returns nil when more bytes are needed (incomplete headers, or body shorter than
    /// `Content-Length`). Never throws — an unparsable request simply never completes,
    /// and the connection is dropped once the client stops sending / closes.
    private static func parseRequest(_ buffer: Data) -> ParsedRequest? {
        let headerTerminator = Data("\r\n\r\n".utf8)
        guard let terminatorRange = buffer.range(of: headerTerminator) else { return nil }
        guard let headBlock = String(data: buffer[..<terminatorRange.lowerBound], encoding: .utf8) else { return nil }

        // First line is the request line ("POST /hook HTTP/1.1") — the server treats
        // every path/method alike, so only the headers are extracted from it.
        var lines = headBlock.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        lines.removeFirst()

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = headers.first { $0.key.caseInsensitiveCompare("Content-Length") == .orderedSame }
            .flatMap { Int($0.value) } ?? 0

        let bodyStart = terminatorRange.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        return ParsedRequest(headers: headers, body: Data(buffer[bodyStart..<bodyEnd]))
    }

    /// `NWEndpoint.Port(rawValue: 0)` isn't a real bindable port — `.any` is the correct
    /// spelling for "let the OS assign an ephemeral one" (which `init(port: 0)` requests).
    private static func wirePort(_ raw: UInt16) -> NWEndpoint.Port {
        raw == 0 ? .any : (NWEndpoint.Port(rawValue: raw) ?? .any)
    }
}
