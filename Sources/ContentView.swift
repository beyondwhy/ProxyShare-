import SwiftUI

struct ContentView: View {
    @StateObject private var controller = ProxyController()
    @AppStorage("port") private var httpPortText = "8080"
    @AppStorage("socksPort") private var socksPortText = "1080"
    @AppStorage("password") private var password = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle("Share connection", isOn: Binding(
                        get: { controller.isRunning },
                        set: { on in
                            if on {
                                controller.start(httpPortText: httpPortText, socksPortText: socksPortText, password: password)
                            } else {
                                controller.stop()
                            }
                        }
                    ))
                    row("Status", controller.status)
                    row("Connections", "\(controller.activeConnections)")
                }

                Section(
                    header: Text("Settings"),
                    footer: Text("With no password, anyone on the same network can use your connection. For SOCKS5, any username works.")
                ) {
                    portField("HTTP port", text: $httpPortText, placeholder: "8080")
                    portField("SOCKS5 port", text: $socksPortText, placeholder: "1080")
                    SecureField("Password (optional)", text: $password)
                }
                .disabled(controller.isRunning)

                Section(
                    header: Text("Proxy address for your PC"),
                    footer: Text("HTTP works in Windows proxy settings (TCP only). SOCKS5 also carries UDP, for apps or VPN-style clients that support it. Turn the proxy off on the PC when you stop sharing.")
                ) {
                    if controller.addresses.isEmpty {
                        Text("Connect to Wi-Fi or turn on Personal Hotspot.")
                            .foregroundColor(.secondary)
                    }
                    ForEach(controller.addresses, id: \.self) { address in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(address.label)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            addressLine("HTTP", "\(address.ip):\(httpPortText)")
                            addressLine("SOCKS5", "\(address.ip):\(socksPortText)")
                        }
                        .padding(.vertical, 2)
                    }
                }

                if let error = controller.errorMessage {
                    Section {
                        Text(error).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("ProxyShare")
        }
        .navigationViewStyle(.stack)
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                controller.refreshAddresses()
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }

    private func portField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(title)
            TextField(placeholder, text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        }
    }

    private func addressLine(_ kind: String, _ value: String) -> some View {
        HStack {
            Text(kind)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
