import Darwin

struct LocalAddress: Hashable {
    let label: String
    let ip: String
}

enum NetworkInfo {
    /// IPv4 addresses other devices can reach: Wi-Fi (en*) and Personal Hotspot (bridge*).
    static func localAddresses() -> [LocalAddress] {
        var result: [LocalAddress] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.ifa_name)
            let label: String
            if name.hasPrefix("en") {
                label = "Wi-Fi"
            } else if name.hasPrefix("bridge") {
                label = "Hotspot"
            } else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(LocalAddress(label: label, ip: String(cString: host)))
            }
        }
        return result
    }
}
