import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Wi-Fi adapter transport (ELM327 Wi-Fi clones, vLinker FS/MC Wi-Fi, OBDLink MX Wi-Fi).
/// Most Wi-Fi ELM adapters listen on 192.168.0.10:35000; some on 192.168.0.123 or port 23.
public final class TCPTransport: Transport {
    public let host: String
    public let port: UInt16
    public let connectTimeout: TimeInterval
    private var fd: Int32 = -1

    public var name: String { "\(host):\(port)" }
    public var isOpen: Bool { fd >= 0 }

    public init(host: String, port: UInt16 = 35000, connectTimeout: TimeInterval = 5) {
        self.host = host
        self.port = port
        self.connectTimeout = connectTimeout
    }

    deinit { close() }

    public func open() throws {
        if isOpen { return }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let ai = res else {
            throw TransportError.openFailed("resolve \(host): \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(res) }

        let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard s >= 0 else { throw TransportError.openFailed("socket: \(String(cString: strerror(errno)))") }
        // Non-blocking connect with timeout.
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        let c = connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
        if c != 0 && errno != EINPROGRESS {
            _ = sysClose(s)
            throw TransportError.openFailed("connect \(name): \(String(cString: strerror(errno)))")
        }
        if c != 0 {
            var p = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            let r = poll(&p, 1, Int32(connectTimeout * 1000))
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
            if r <= 0 || err != 0 {
                _ = sysClose(s)
                throw TransportError.openFailed("connect \(name): \(r <= 0 ? "timed out" : String(cString: strerror(err)))")
            }
        }
        var one: Int32 = 1
        setsockopt(s, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        fd = s
    }

    public func close() {
        if fd >= 0 { _ = sysClose(fd); fd = -1 }
    }

    public func write(_ data: Data) throws {
        guard isOpen else { throw TransportError.notOpen }
        var offset = 0
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            while offset < buf.count {
                let n = sysWrite(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 {
                    if errno == EAGAIN { usleep(1000); continue }
                    throw TransportError.writeFailed(String(cString: strerror(errno)))
                }
                offset += n
            }
        }
    }

    public func read(timeout: TimeInterval) throws -> Data {
        guard isOpen else { throw TransportError.notOpen }
        guard try waitReadable(fd: fd, timeout: timeout) else { return Data() }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = sysRead(fd, &buf, buf.count)
        if n == 0 { close(); throw TransportError.readFailed("adapter closed the connection") }
        if n < 0 {
            if errno == EAGAIN { return Data() }
            throw TransportError.readFailed(String(cString: strerror(errno)))
        }
        return Data(buf[0..<n])
    }
}
