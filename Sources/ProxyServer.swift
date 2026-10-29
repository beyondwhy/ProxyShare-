import Foundation
import Network

/// One proxied client connection, HTTP or SOCKS5.
protocol RelaySession: AnyObject {
    var onClose: (() -> Void)? { get set }
    func start()
    func close()
}

/// Copies bytes from `source` to `destination` until either side ends or fails, then calls `onEnd`.
func relay(from source: NWConnection, to destination: NWConnection,
           isClosed: @escaping () -> Bool, onEnd: @escaping () -> Void) {
    source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
        guard !isClosed() else { return }
        if let data = data, !data.isEmpty {
            destination.send(content: data, completion: .contentProcessed { sendError in
                guard !isClosed() else { return }
                if sendError != nil || error != nil || isComplete {
                    onEnd()
                } else {
                    relay(from: source, to: destination, isClosed: isClosed, onEnd: onEnd)
                }
            })
        } else if isComplete || error != nil {
            onEnd()
        } else {
            relay(from: source, to: destination, isClosed: isClosed, onEnd: onEnd)
        }
    }
}

/// Runs the HTTP/HTTPS proxy (the Swift version of the original a-Shell proxy.py) and a SOCKS5 proxy
/// for UDP. All networking runs on one serial queue; callbacks are delivered on the main queue.
final class ProxyServer {
    var onStatus: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onConnectionCount: ((Int) -> Void)?

    private let queue = DispatchQueue(label: "proxyshare.server")
    private var listeners: [NWListener] = []
    private var readyCount = 0
    private var sessions: [ObjectIdentifier: RelaySession] = [:]
    private var password = ""

    func start(httpPort: UInt16, socksPort: UInt16, password: String) throws {
        stop()
        let http = try makeListener(port: httpPort, name: "HTTP") { connection, password, queue in
            ProxySession(client: connection, password: password, queue: queue)
        }
        let socks = try makeListener(port: socksPort, name: "SOCKS5") { connection, password, queue in
            Socks5Session(client: connection, password: password, queue: queue)
        }
        queue.sync {
            self.password = password
            self.readyCount = 0
            self.listeners = [http, socks]
        }
        http.start(queue: queue)
        socks.start(queue: queue)
    }

    func stop() {
        queue.sync {
            listeners.forEach { $0.cancel() }
            listeners.removeAll()
            let all = Array(sessions.values)
            sessions.removeAll()
            all.forEach { $0.close() }
        }
        report(status: "Stopped")
        reportCount(0)
    }

    private func makeListener(
        port: UInt16, name: String,
        makeSession: @escaping (NWConnection, String, DispatchQueue) -> RelaySession
    ) throws -> NWListener {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "ProxyShare", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid \(name) port"])
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: nwPort)

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self = self, let listener = listener, self.listeners.contains(where: { $0 === listener }) else { return }
            switch state {
            case .ready:
                self.readyCount += 1
                if self.readyCount == self.listeners.count {
                    self.report(status: "Running")
                }
            case .failed(let error):
                self.listeners.forEach { $0.cancel() }
                self.listeners.removeAll()
                let message = "Could not start \(name) on port \(port): \(error.localizedDescription)"
                DispatchQueue.main.async { self.onFailure?(message) }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return connection.cancel() }
            self.accept(makeSession(connection, self.password, self.queue))
        }
        return listener
    }

    private func accept(_ session: RelaySession) {
        let id = ObjectIdentifier(session)
        sessions[id] = session
        session.onClose = { [weak self] in
            guard let self = self else { return }
            self.sessions[id] = nil
            self.reportCount(self.sessions.count)
        }
        reportCount(sessions.count)
        session.start()
    }

    private func report(status: String) {
        DispatchQueue.main.async { self.onStatus?(status) }
    }

    private func reportCount(_ count: Int) {
        DispatchQueue.main.async { self.onConnectionCount?(count) }
    }
}

/// One HTTP proxy connection: reads the request head, connects upstream, then pipes bytes both ways.
final class ProxySession: RelaySession {
    var onClose: (() -> Void)?

    private let client: NWConnection
    private var upstream: NWConnection?
    private let password: String
    private let queue: DispatchQueue
    private var buffer = Data()
    private var closed = false

    private static let headTerminator = Data("\r\n\r\n".utf8)
    private static let maxHeadSize = 64 * 1024
    private static let chunkSize = 64 * 1024

    init(client: NWConnection, password: String, queue: DispatchQueue) {
        self.client = client
        self.password = password
        self.queue = queue
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        client.start(queue: queue)
        readHead()
    }

    func close() {
        guard !closed else { return }
        closed = true
        client.cancel()
        upstream?.cancel()
        let callback = onClose
        onClose = nil
        callback?()
    }

    // MARK: - Request head

    private func readHead() {
        client.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkSize) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.closed else { return }
            if let data = data {
                self.buffer.append(data)
            }
            if let range = self.buffer.range(of: Self.headTerminator) {
                let head = self.buffer.subdata(in: self.buffer.startIndex..<range.lowerBound)
                let rest = self.buffer.subdata(in: range.upperBound..<self.buffer.endIndex)
                self.buffer = Data()
                self.handle(head: head, rest: rest)
            } else if isComplete || error != nil || self.buffer.count > Self.maxHeadSize {
                self.close()
            } else {
                self.readHead()
            }
        }
    }

    private func handle(head: Data, rest: Data) {
        guard let text = String(data: head, encoding: .utf8) else { return close() }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let headers = lines.filter { !$0.isEmpty }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return close() }
        let method = parts[0], target = parts[1], version = parts[2]

        if !password.isEmpty && !isAuthorized(headers) {
            return respondAndClose(
                "HTTP/1.1 407 Proxy Authentication Required\r\n" +
                "Proxy-Authenticate: Basic realm=\"ProxyShare\"\r\n" +
                "Content-Length: 0\r\nConnection: close\r\n\r\n"
            )
        }

        if method.uppercased() == "CONNECT" {
            handleConnect(target: target, rest: rest)
        } else {
            handlePlain(method: method, target: target, version: version, headers: headers, rest: rest)
        }
    }

    private func isAuthorized(_ headers: [String]) -> Bool {
        guard let header = headers.first(where: { $0.lowercased().hasPrefix("proxy-authorization:") }) else {
            return false
        }
        let value = header.dropFirst("proxy-authorization:".count).trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("basic ") else { return false }
        let encoded = value.dropFirst("basic ".count).trimmingCharacters(in: .whitespaces)
        guard let decoded = Data(base64Encoded: encoded).flatMap({ String(data: $0, encoding: .utf8) }),
              let colon = decoded.firstIndex(of: ":") else {
            return false
        }
        // Any username is accepted; only the password is checked.
        return decoded[decoded.index(after: colon)...] == password
    }

    // MARK: - CONNECT (HTTPS tunnels)

    private func handleConnect(target: String, rest: Data) {
        guard let colon = target.lastIndex(of: ":"),
              let port = UInt16(target[target.index(after: colon)...]) else {
            return respondAndClose("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        }
        let host = target[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        connectUpstream(host: host, port: port) { [weak self] upstream in
            guard let self = self else { return }
            let established = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
            self.client.send(content: established, completion: .contentProcessed { [weak self] error in
                guard let self = self, !self.closed else { return }
                if error != nil { return self.close() }
                if !rest.isEmpty {
                    upstream.send(content: rest, completion: .contentProcessed { _ in })
                }
                self.startPiping(upstream)
            })
        }
    }

    // MARK: - Plain HTTP

    private func handlePlain(method: String, target: String, version: String, headers: [String], rest: Data) {
        guard let url = URLComponents(string: target), let host = url.host,
              let port = UInt16(exactly: url.port ?? 80) else {
            return respondAndClose("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        }
        var path = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
        if let query = url.percentEncodedQuery {
            path += "?" + query
        }

        // One request per connection, so a reused client connection can't be sent to the wrong host.
        let dropped: Set<String> = ["proxy-authorization", "proxy-connection", "connection", "keep-alive"]
        let kept = headers.filter { line in
            let name = line.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            return !dropped.contains(name)
        }
        var outgoing = "\(method) \(path) \(version)\r\n"
        kept.forEach { outgoing += $0 + "\r\n" }
        outgoing += "Connection: close\r\n\r\n"
        let request = Data(outgoing.utf8) + rest

        connectUpstream(host: host, port: port) { [weak self] upstream in
            guard let self = self else { return }
            upstream.send(content: request, completion: .contentProcessed { _ in })
            self.startPiping(upstream)
        }
    }

    // MARK: - Upstream and piping

    private func connectUpstream(host: String, port: UInt16, onReady: @escaping (NWConnection) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port), port != 0 else {
            return respondAndClose("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        upstream = connection
        var ready = false
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if !ready {
                    ready = true
                    onReady(connection)
                }
            case .waiting, .failed:
                // .waiting means DNS failed or the host refused; it would otherwise hang.
                if ready {
                    self.close()
                } else {
                    self.respondAndClose("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                }
            case .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func startPiping(_ upstream: NWConnection) {
        let isClosed: () -> Bool = { [weak self] in self?.closed ?? true }
        let end: () -> Void = { [weak self] in self?.close() }
        relay(from: client, to: upstream, isClosed: isClosed, onEnd: end)
        relay(from: upstream, to: client, isClosed: isClosed, onEnd: end)
    }

    private func respondAndClose(_ response: String) {
        guard !closed else { return }
        client.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }
}
