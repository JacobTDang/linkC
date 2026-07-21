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
    private let maxRequestBytes: Int
    private let queue = DispatchQueue(label: "com.linkc.hookserver")
    private let stateLock = NSLock()
    private var _resolvedPort: UInt16
    private var listener: NWListener?
    /// Accepted connections still in flight, keyed by identity. Guarded by `stateLock` so
    /// `stop()` can cancel them all; entries are removed as each connection completes.
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var _onEvent: (@Sendable (HookEvent) -> Void)?

    /// Called on each decoded event. The caller is responsible for hopping to the main actor.
    /// Invoked on the server's internal queue — keep it fast; it runs before the response
    /// is sent, but the response path itself does no other work regardless. Guarded by
    /// `stateLock` (like `listener`/`_resolvedPort`) since it is set on the caller's thread
    /// and read on the dispatch queue.
    public var onEvent: (@Sendable (HookEvent) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onEvent }
        set { stateLock.lock(); _onEvent = newValue; stateLock.unlock() }
    }

    /// - Parameter maxRequestBytes: hard cap on the total header+body bytes buffered for a
    ///   single request. A connection that exceeds it (or declares a larger `Content-Length`)
    ///   is dropped, bounding memory against a buggy/hostile local client.
    public init(port: UInt16, maxRequestBytes: Int = 1 << 20) {
        self.requestedPort = port
        self._resolvedPort = port
        self.maxRequestBytes = maxRequestBytes
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

    /// Cancels the listener and every in-flight connection. Idempotent; safe to call even
    /// if `start()` was never called or already failed.
    public func stop() {
        stateLock.lock()
        let current = listener
        listener = nil
        let liveConnections = Array(connections.values)
        connections.removeAll()
        stateLock.unlock()
        current?.cancel()
        for connection in liveConnections {
            connection.cancel()
        }
    }

    // MARK: - Connection handling

    private func track(_ connection: NWConnection) {
        stateLock.lock()
        connections[ObjectIdentifier(connection)] = connection
        stateLock.unlock()
    }

    private func untrack(_ connection: NWConnection) {
        stateLock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        stateLock.unlock()
    }

    private func accept(_ connection: NWConnection) {
        track(connection)
        connection.start(queue: queue)
        receive(on: connection, buffered: Data())
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                // Server deallocated mid-receive — don't leak the fd.
                connection.cancel()
                return
            }

            var buffer = buffered
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            switch Self.parseRequest(buffer, maxBytes: self.maxRequestBytes) {
            case .complete(let request):
                self.respond(on: connection, request: request)
                return
            case .tooLarge:
                // Bounded: reject an oversized request rather than buffering it. Never
                // sends a response — this path is only reachable for buggy/hostile clients.
                self.untrack(connection)
                connection.cancel()
                return
            case .incomplete:
                break
            }

            guard error == nil, !isComplete else {
                self.untrack(connection)
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
        let handler = onEvent // synchronized read (see `onEvent`)
        if let event = HookEventDecoder.decode(headers: request.headers, body: request.body) {
            handler?(event)
        }

        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.untrack(connection)
            connection.cancel()
        })
    }

    // MARK: - Minimal HTTP/1.1 request parsing

    private struct ParsedRequest {
        let headers: [String: String]
        let body: Data
    }

    private enum ParseResult {
        case complete(ParsedRequest)
        case incomplete   // more bytes needed
        case tooLarge     // exceeds `maxBytes` — drop the connection
    }

    /// `.incomplete` when more bytes are needed (incomplete headers, or body shorter than
    /// `Content-Length`); `.tooLarge` when the buffered bytes or a declared `Content-Length`
    /// exceed `maxBytes`. Never throws — a merely unparsable request simply never completes,
    /// and the connection is dropped once the client stops sending / closes.
    private static func parseRequest(_ buffer: Data, maxBytes: Int) -> ParseResult {
        if buffer.count > maxBytes { return .tooLarge }

        let headerTerminator = Data("\r\n\r\n".utf8)
        guard let terminatorRange = buffer.range(of: headerTerminator) else { return .incomplete }
        guard let headBlock = String(data: buffer[..<terminatorRange.lowerBound], encoding: .utf8) else { return .incomplete }

        // First line is the request line ("POST /hook HTTP/1.1") — the server treats
        // every path/method alike, so only the headers are extracted from it.
        var lines = headBlock.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .incomplete }
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
        // Reject a declared body larger than the cap up front, before waiting to buffer it.
        if contentLength > maxBytes { return .tooLarge }

        let bodyStart = terminatorRange.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else { return .incomplete }
        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        return .complete(ParsedRequest(headers: headers, body: Data(buffer[bodyStart..<bodyEnd])))
    }

    /// `NWEndpoint.Port(rawValue: 0)` isn't a real bindable port — `.any` is the correct
    /// spelling for "let the OS assign an ephemeral one" (which `init(port: 0)` requests).
    private static func wirePort(_ raw: UInt16) -> NWEndpoint.Port {
        raw == 0 ? .any : (NWEndpoint.Port(rawValue: raw) ?? .any)
    }
}
