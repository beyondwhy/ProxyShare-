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

    func start(portText: String, password: String) {
        guard let port = UInt16(portText), port > 0 else {
            errorMessage = "Port must be a number from 1 to 65535."
            return
        }
        do {
            try keeper.start()
            try server.start(port: port, password: password)
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
