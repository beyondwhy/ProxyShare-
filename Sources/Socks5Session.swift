import Foundation
import Network

/// SOCKS5 (RFC 1928): CONNECT for TCP and UDP ASSOCIATE for UDP, with username/password auth (RFC 1929).
final class Socks5Session: RelaySession {
    var onClose: (() -> Void)?

    private let client: NWConnection
    private let password: String
    private let queue: DispatchQueue
    private var upstream: NWConnection?
    private var udpRelay: UDPRelay?
    private var buffer = Data()
    private var closed = false

    private enum Reply: UInt8 {
        case succeeded = 0x00
        case generalFailure = 0x01
        case hostUnreachable = 0x04
        case commandNotSupported = 0x07
        case addressNotSupported = 0x08
    }

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
        readGreeting()
    }

    func close() {
        guard !closed else { return }
        closed = true
        client.cancel()
        upstream?.cancel()
        udpRelay?.stop()
        let callback = onClose
        onClose = nil
        callback?()
    }

    // MARK: - Reading

    /// Calls `handler` with exactly `count` bytes from the client.
    private func read(_ count: Int, then handler: @escaping ([UInt8]) -> Void) {
        if buffer.count >= count {
            let chunk = [UInt8](buffer.prefix(count))
            buffer = Data(buffer.dropFirst(count))
            return handler(chunk)
        }
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.closed else { return }
            if let data = data {
                self.buffer.append(data)
            }
            if self.buffer.count >= count || (!isComplete && error == nil) {
                self.read(count, then: handler)
            } else {
                self.close()
            }
        }
    }

    // MARK: - Handshake

    private func readGreeting() {
        read(2) { [weak self] head in
            guard let self = self else { return }
            guard head[0] == 5 else { return self.close() }
            self.read(Int(head[1])) { [weak self] methods in
                guard let self = self else { return }
                let wanted: UInt8 = self.password.isEmpty ? 0x00 : 0x02
                guard methods.contains(wanted) else {
                    return self.sendAndClose([5, 0xFF])
                }
                self.send([5, wanted]) {
                    wanted == 0x02 ? self.readCredentials() : self.readRequest()
                }
            }
        }
    }

    private func readCredentials() {
        read(2) { [weak self] head in
            guard let self = self else { return }
            self.read(Int(head[1]) + 1) { [weak self] userAndLength in
                guard let self = self, let passwordLength = userAndLength.last else { return }
                self.read(Int(passwordLength)) { [weak self] passwordBytes in
                    guard let self = self else { return }
                    // Any username is accepted; only the password is checked.
                    guard String(bytes: passwordBytes, encoding: .utf8) == self.password else {
                        return self.sendAndClose([1, 1])
                    }
                    self.send([1, 0]) { self.readRequest() }
                }
            }
        }
    }

    private func readRequest() {
        read(4) { [weak self] head in
            guard let self = self else { return }
            guard head[0] == 5 else { return self.close() }
            let command = head[1], addressType = head[3]
            let finish: ([UInt8]) -> Void = { [weak self] addressAndPort in
                guard let self = self else { return }
                guard let target = SocksAddress.parse([addressType] + addressAndPort, from: 0)?.0 else {
                    return self.reply(.addressNotSupported, close: true)
                }
                switch command {
                case 1:
                    self.connect(to: target)
                case 3:
                    self.associateUDP()
                default:
                    self.reply(.commandNotSupported, close: true)
                }
            }
            switch addressType {
            case 1:
                self.read(4 + 2, then: finish)
            case 4:
                self.read(16 + 2, then: finish)
            case 3:
                self.read(1) { [weak self] length in
                    self?.read(Int(length[0]) + 2) { finish(length + $0) }
                }
            default:
                self.reply(.addressNotSupported, close: true)
            }
        }
    }

    // MARK: - CONNECT (TCP)

    private func connect(to target: SocksAddress) {
        let connection = NWConnection(host: target.host, port: target.port, using: .tcp)
        upstream = connection
        var ready = false
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                guard !ready else { return }
                ready = true
                self.reply(.succeeded) {
                    if !self.buffer.isEmpty {
                        connection.send(content: self.buffer, completion: .contentProcessed { _ in })
                        self.buffer = Data()
                    }
                    let isClosed: () -> Bool = { [weak self] in self?.closed ?? true }
                    let end: () -> Void = { [weak self] in self?.close() }
                    relay(from: self.client, to: connection, isClosed: isClosed, onEnd: end)
                    relay(from: connection, to: self.client, isClosed: isClosed, onEnd: end)
                }
            case .waiting, .failed:
                // .waiting means DNS failed or the host refused; it would otherwise hang.
                if ready {
                    self.close()
                } else {
                    self.reply(.hostUnreachable, close: true)
                }
            case .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: - UDP ASSOCIATE

    private func associateUDP() {
        guard case .hostPort(let localHost, _)? = client.currentPath?.localEndpoint,
              case .hostPort(let clientHost, _)? = client.currentPath?.remoteEndpoint else {
            return reply(.generalFailure, close: true)
        }
        let udp = UDPRelay(clientHost: clientHost, queue: queue)
        udpRelay = udp
        udp.start { [weak self] port in
            guard let self = self, !self.closed else { return }
            guard let port = port else { return self.reply(.generalFailure, close: true) }
            self.reply(.succeeded, boundHost: localHost, boundPort: port) {
                self.waitForControlClose()
            }
        }
    }

    /// The UDP association lasts as long as the client keeps this TCP connection open.
    private func waitForControlClose() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, isComplete, error in
            guard let self = self, !self.closed else { return }
            if isComplete || error != nil {
                self.close()
            } else {
                self.waitForControlClose()
            }
        }
    }

    // MARK: - Writing

    private func reply(_ code: Reply, boundHost: NWEndpoint.Host? = nil, boundPort: UInt16 = 0,
                       close: Bool = false, then next: (() -> Void)? = nil) {
        var bytes: [UInt8] = [5, code.rawValue, 0]
        switch boundHost.map(SocksAddress.normalized) {
        case .ipv4(let address)?:
            bytes += [1] + [UInt8](address.rawValue)
        case .ipv6(let address)?:
            bytes += [4] + [UInt8](address.rawValue)
        default:
            bytes += [1, 0, 0, 0, 0]
        }
        bytes += [UInt8(boundPort >> 8), UInt8(boundPort & 0xFF)]
        if close {
            sendAndClose(bytes)
        } else {
            send(bytes) { next?() }
        }
    }

    private func send(_ bytes: [UInt8], then next: @escaping () -> Void) {
        client.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            guard let self = self, !self.closed else { return }
            if error != nil {
                self.close()
            } else {
                next()
            }
        })
    }

    private func sendAndClose(_ bytes: [UInt8]) {
        guard !closed else { return }
        client.send(content: Data(bytes), completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }
}

/// A SOCKS5 address: ATYP, address and port, as used in requests and UDP datagram headers.
struct SocksAddress {
    let host: NWEndpoint.Host
    let port: NWEndpoint.Port
    /// The bytes exactly as the client sent them, reused in UDP reply headers.
    let raw: [UInt8]

    /// Parses an address starting at `start`; returns it and the index just past the port.
    static func parse(_ bytes: [UInt8], from start: Int) -> (SocksAddress, Int)? {
        guard start < bytes.count else { return nil }
        var index = start + 1
        let host: NWEndpoint.Host
        switch bytes[start] {
        case 1:
            guard bytes.count >= index + 4, let address = IPv4Address(Data(bytes[index..<index + 4])) else { return nil }
            host = .ipv4(address)
            index += 4
        case 3:
            guard bytes.count > index else { return nil }
            let length = Int(bytes[index])
            index += 1
            guard bytes.count >= index + length,
                  let name = String(bytes: bytes[index..<index + length], encoding: .utf8) else { return nil }
            host = .name(name, nil)
            index += length
        case 4:
            guard bytes.count >= index + 16, let address = IPv6Address(Data(bytes[index..<index + 16])) else { return nil }
            host = .ipv6(address)
            index += 16
        default:
            return nil
        }
        guard bytes.count >= index + 2,
              let port = NWEndpoint.Port(rawValue: UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])) else { return nil }
        index += 2
        return (SocksAddress(host: host, port: port, raw: Array(bytes[start..<index])), index)
    }

    /// Turns IPv4-mapped IPv6 addresses (::ffff:a.b.c.d) into plain IPv4.
    static func normalized(_ host: NWEndpoint.Host) -> NWEndpoint.Host {
        if case .ipv6(let address) = host, let ipv4 = address.asIPv4 {
            return .ipv4(ipv4)
        }
        return host
    }

    /// Raw address bytes, for comparing hosts regardless of interface scope.
    static func rawBytes(_ host: NWEndpoint.Host) -> Data? {
        switch normalized(host) {
        case .ipv4(let address):
            return address.rawValue
        case .ipv6(let address):
            return address.rawValue
        default:
            return nil
        }
    }
}

/// Relays SOCKS5 UDP datagrams between one client and any number of destinations.
final class UDPRelay {
    private struct FlowKey: Hashable {
        let inbound: ObjectIdentifier
        let target: [UInt8]
    }

    private let clientAddress: Data?
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var inbound: [ObjectIdentifier: NWConnection] = [:]
    private var flows: [FlowKey: NWConnection] = [:]
    private var stopped = false

    private static let maxFlows = 256

    init(clientHost: NWEndpoint.Host, queue: DispatchQueue) {
        self.clientAddress = SocksAddress.rawBytes(clientHost)
        self.queue = queue
    }

    /// Opens a UDP port and reports its number, or nil if it couldn't be opened.
    func start(onReady: @escaping (UInt16?) -> Void) {
        guard let listener = try? NWListener(using: .udp, on: .any) else { return onReady(nil) }
        self.listener = listener
        var reported = false
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                guard !reported else { return }
                reported = true
                onReady(listener?.port?.rawValue)
            case .failed:
                guard !reported else { return }
                reported = true
                onReady(nil)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        listener?.cancel()
        inbound.values.forEach { $0.cancel() }
        flows.values.forEach { $0.cancel() }
        inbound.removeAll()
        flows.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        // Only the device that opened the association may use this port.
        guard !stopped, case .hostPort(let host, _) = connection.endpoint,
              let address = SocksAddress.rawBytes(host), address == clientAddress else {
            return connection.cancel()
        }
        inbound[ObjectIdentifier(connection)] = connection
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self = self, let connection = connection, !self.stopped else { return }
            if let data = data, !data.isEmpty {
                self.forward([UInt8](data), from: connection)
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }

    /// Datagram from the client: RSV(2) FRAG(1) address payload.
    private func forward(_ datagram: [UInt8], from connection: NWConnection) {
        guard datagram.count > 3, datagram[2] == 0,  // fragmented datagrams are not supported
              let parsed = SocksAddress.parse(datagram, from: 3) else { return }
        let (target, payloadStart) = parsed
        let payload = Data(datagram[payloadStart...])
        let key = FlowKey(inbound: ObjectIdentifier(connection), target: target.raw)

        if let flow = flows[key] {
            flow.send(content: payload, completion: .idempotent)
            return
        }
        guard flows.count < Self.maxFlows else { return }

        let flow = NWConnection(host: target.host, port: target.port, using: .udp)
        flows[key] = flow
        flow.stateUpdateHandler = { [weak self, weak flow] state in
            switch state {
            case .failed, .cancelled:
                flow?.cancel()
                self?.flows[key] = nil
            default:
                break
            }
        }
        flow.start(queue: queue)
        flow.send(content: payload, completion: .idempotent)
        receiveReplies(on: flow, for: target, to: connection)
    }

    /// Datagram back to the client, with the header naming where it came from.
    private func receiveReplies(on flow: NWConnection, for target: SocksAddress, to connection: NWConnection) {
        flow.receiveMessage { [weak self, weak flow, weak connection] data, _, _, error in
            guard let self = self, let flow = flow, let connection = connection, !self.stopped else { return }
            if let data = data, !data.isEmpty {
                connection.send(content: Data([0, 0, 0] + target.raw) + data, completion: .idempotent)
            }
            if error == nil {
                self.receiveReplies(on: flow, for: target, to: connection)
            }
        }
    }
}
