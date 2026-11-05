import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An IPv4 network adapter (Ethernet, Wi-Fi, USB LAN …).
public struct NetworkInterface: Hashable, Identifiable, Sendable {
    public var name: String          // BSD name, e.g. "en0"
    public var address: String       // e.g. "192.168.1.20"
    public var netmask: String       // e.g. "255.255.255.0"
    public var id: String { name }

    public init(name: String, address: String, netmask: String) {
        self.name = name; self.address = address; self.netmask = netmask
    }

    /// Whether `host` (an IPv4 address) is on this adapter's subnet.
    public func reaches(_ host: String) -> Bool {
        guard let a = Self.ipv4(address), let m = Self.ipv4(netmask), let h = Self.ipv4(host) else { return false }
        return a & m == h & m
    }

    static func ipv4(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return nil }
        return parts.reduce(0) { $0 << 8 | $1 }
    }

    /// Active IPv4 adapters, excluding loopback.
    public static func all() -> [NetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [NetworkInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  flags & Int32(IFF_UP) != 0, flags & Int32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            let address = string(addr)
            let mask = ifa.pointee.ifa_netmask.map(string) ?? ""
            if !result.contains(where: { $0.name == name }) {
                result.append(NetworkInterface(name: name, address: address, netmask: mask))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    private static func string(_ sa: UnsafeMutablePointer<sockaddr>) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            var a = sin.pointee.sin_addr
            _ = inet_ntop(AF_INET, &a, &buffer, socklen_t(INET_ADDRSTRLEN))
        }
        return String(cString: buffer)
    }
}
