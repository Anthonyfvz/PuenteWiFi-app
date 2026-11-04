import Darwin
import Foundation

struct LocalAddress: Identifiable, Equatable, Sendable {
    var interface: String
    var ip: String
    var id: String { interface + ip }

    var label: String {
        interface.hasPrefix("bridge") ? "Hotspot personal" : "Wi-Fi"
    }
}

enum NetworkInfo {
    /// IPv4 addresses other devices can use to reach this phone.
    static func localAddresses() -> [LocalAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }

        var results: [LocalAddress] = []
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard
                name == "en0" || name.hasPrefix("bridge"),
                entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                let address = entry.pointee.ifa_addr,
                address.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                address, socklen_t(address.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            )
            if status == 0 {
                results.append(LocalAddress(interface: name, ip: String(cString: host)))
            }
        }
        return results.sorted { $0.interface > $1.interface }
    }
}
