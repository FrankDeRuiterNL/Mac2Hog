import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Minimal UDP OSC sender (and optional receiver for Hog status feedback) built on BSD sockets
/// so it behaves identically on macOS and in Linux CI.
public final class OSCSender: @unchecked Sendable {
    public enum SocketError: Error, LocalizedError {
        case resolve(String), socket(Int32), send(Int32), bind(Int32), interface(String)
        public var errorDescription: String? {
            switch self {
            case .resolve(let host): return "Could not resolve host \(host)"
            case .socket(let e): return "Socket error \(e): \(String(cString: strerror(e)))"
            case .send(let e): return "Send failed \(e): \(String(cString: strerror(e)))"
            case .bind(let e): return "Bind failed \(e): \(String(cString: strerror(e)))"
            case .interface(let name): return "Network adapter \(name) is not available"
            }
        }
    }

    public let host: String
    public let port: UInt16
    private var fd: Int32 = -1
    private var address = sockaddr_in()
    private let lock = NSLock()

    /// `interface`: BSD name of the adapter to send from (e.g. "en7"); nil = system routing.
    public init(host: String, port: UInt16, interface: String? = nil) throws {
        self.host = host
        self.port = port
        #if canImport(Darwin)
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        #else
        fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_UDP))
        #endif
        guard fd >= 0 else { throw SocketError.socket(errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        if let name = interface, !name.isEmpty {
            var index = Int32(bitPattern: if_nametoindex(name))
            guard index != 0 else { close(fd); fd = -1; throw SocketError.interface(name) }
            #if canImport(Darwin)
            // IP_BOUND_IF (25): send only through this adapter.
            setsockopt(fd, IPPROTO_IP, 25, &index, socklen_t(MemoryLayout<Int32>.size))
            #else
            _ = index
            #endif
        }
        address = try Self.resolve(host: host, port: port)
    }

    deinit { if fd >= 0 { close(fd) } }

    static func resolve(host: String, port: UInt16) throws -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if inet_pton(AF_INET, host, &addr.sin_addr) == 1 { return addr }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result, let sa = info.pointee.ai_addr else {
            throw SocketError.resolve(host)
        }
        defer { freeaddrinfo(result) }
        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addr.sin_addr = $0.pointee.sin_addr }
        return addr
    }

    public func send(_ message: OSCMessage) throws {
        try send(data: message.encoded())
    }

    public func send(data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        var addr = address
        let sent = data.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 { throw SocketError.send(errno) }
    }
}

/// Listens for OSC messages on a UDP port (used to show Hog 4 status/feedback output).
public final class OSCListener: @unchecked Sendable {
    private var fd: Int32 = -1
    private var running = false
    private let queue = DispatchQueue(label: "mac2hog.osc.listener")
    public let port: UInt16

    public init(port: UInt16) { self.port = port }

    public func start(handler: @escaping @Sendable (OSCMessage) -> Void) throws {
        stop()
        #if canImport(Darwin)
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        #else
        fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_UDP))
        #endif
        guard fd >= 0 else { throw OSCSender.SocketError.socket(errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { let e = errno; close(fd); fd = -1; throw OSCSender.SocketError.bind(e) }
        running = true
        let sock = fd
        queue.async { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while self?.running == true {
                let n = recv(sock, &buffer, buffer.count, 0)
                if n > 0, let msg = try? OSCMessage.decode(Data(buffer[0..<n])) { handler(msg) }
            }
            close(sock)
        }
    }

    public func stop() {
        running = false
        fd = -1
    }

    deinit { running = false }
}
