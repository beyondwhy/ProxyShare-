import SwiftUI

struct ContentView: View {
    @StateObject private var controller = ProxyController()
    @AppStorage("port") private var portText = "8080"
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
                                controller.start(portText: portText, password: password)
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
                    footer: Text("With no password, anyone on the same network can use your connection.")
                ) {
                    HStack {
                        Text("Port")
                        TextField("8080", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    SecureField("Password (optional)", text: $password)
                }
                .disabled(controller.isRunning)

                Section(
                    header: Text("Proxy address for your PC"),
                    footer: Text("Windows: Settings → Network & internet → Proxy → Manual proxy setup. Turn it off on the PC when you stop sharing.")
                ) {
                    if controller.addresses.isEmpty {
                        Text("Connect to Wi-Fi or turn on Personal Hotspot.")
                            .foregroundColor(.secondary)
                    }
                    ForEach(controller.addresses, id: \.self) { address in
                        HStack {
                            Text(address.label)
                            Spacer()
                            Text("\(address.ip):\(portText)")
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
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
}
