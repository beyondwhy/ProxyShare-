import Foundation

/// Ties the proxy server and the background keeper together for the UI. Used on the main thread only.
final class ProxyController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Stopped"
    @Published private(set) var activeConnections = 0
    @Published private(set) var addresses: [LocalAddress] = []
    @Published private(set) var errorMessage: String?

    private let server = ProxyServer()
    private let keeper = BackgroundKeeper()

    init() {
        server.onStatus = { [weak self] status in
            self?.status = status
        }
        server.onConnectionCount = { [weak self] count in
            self?.activeConnections = count
        }
        server.onFailure = { [weak self] message in
            self?.stop()
            self?.errorMessage = message
        }
        refreshAddresses()
    }

    func start(httpPortText: String, socksPortText: String, password: String) {
        guard let httpPort = UInt16(httpPortText), httpPort > 0,
              let socksPort = UInt16(socksPortText), socksPort > 0 else {
            errorMessage = "Ports must be numbers from 1 to 65535."
            return
        }
        guard httpPort != socksPort else {
            errorMessage = "The HTTP and SOCKS5 ports must be different."
            return
        }
        do {
            try keeper.start()
            try server.start(httpPort: httpPort, socksPort: socksPort, password: password)
            isRunning = true
            errorMessage = nil
        } catch {
            server.stop()
            keeper.stop()
            isRunning = false
            errorMessage = error.localizedDescription
        }
        refreshAddresses()
    }

    func stop() {
        server.stop()
        keeper.stop()
        isRunning = false
    }

    func refreshAddresses() {
        addresses = NetworkInfo.localAddresses()
    }
}
