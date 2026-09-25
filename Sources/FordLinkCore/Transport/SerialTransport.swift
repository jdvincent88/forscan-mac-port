import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// POSIX serial port transport for USB adapters (OBDLink EX/SX, vLinker FS USB, ELM327 USB clones).
///
/// On macOS always use the `/dev/cu.*` device, not `/dev/tty.*` — the `tty` node blocks on
/// carrier detect and will hang.
public final class SerialTransport: Transport {
    public let path: String
    public private(set) var baud: Int
    private var fd: Int32 = -1

    public var name: String { "\(path)@\(baud)" }
    public var isOpen: Bool { fd >= 0 }

    public init(path: String, baud: Int = 38400) {
        self.path = path
        self.baud = baud
    }

    deinit { close() }

    public func open() throws {
        if isOpen { return }
        let f = path.withCString { sysOpen($0, O_RDWR | O_NOCTTY | O_NONBLOCK) }
        guard f >= 0 else { throw TransportError.openFailed("\(path): \(String(cString: strerror(errno)))") }
        fd = f
        do { try configure(baud: baud) } catch { close(); throw error }
    }

    public func close() {
        if fd >= 0 { _ = sysClose(fd); fd = -1 }
    }

    public func setBaudRate(_ baud: Int) throws {
        self.baud = baud
        if isOpen { try configure(baud: baud) }
    }

    private func configure(baud: Int) throws {
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { throw TransportError.configurationFailed("tcgetattr") }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CRTSCTS)
        t.c_cflag &= ~tcflag_t(CSTOPB)
        t.c_cflag &= ~tcflag_t(PARENB)
        t.c_cflag = (t.c_cflag & ~tcflag_t(CSIZE)) | tcflag_t(CS8)
        #if canImport(Darwin)
        // macOS accepts arbitrary rates directly (needed for 500000/2000000 on STN chips).
        cfsetispeed(&t, speed_t(baud))
        cfsetospeed(&t, speed_t(baud))
        #else
        let sp = SerialTransport.linuxSpeed(baud)
        cfsetispeed(&t, sp)
        cfsetospeed(&t, sp)
        #endif
        guard tcsetattr(fd, TCSANOW, &t) == 0 else {
            throw TransportError.configurationFailed("tcsetattr baud \(baud): \(String(cString: strerror(errno)))")
        }
        tcflush(fd, TCIOFLUSH)
    }

    #if !canImport(Darwin)
    static func linuxSpeed(_ baud: Int) -> speed_t {
        switch baud {
        case 9600: return speed_t(B9600)
        case 19200: return speed_t(B19200)
        case 38400: return speed_t(B38400)
        case 57600: return speed_t(B57600)
        case 115200: return speed_t(B115200)
        case 230400: return speed_t(B230400)
        case 460800: return speed_t(B460800)
        case 500000: return speed_t(B500000)
        case 921600: return speed_t(B921600)
        case 1000000: return speed_t(B1000000)
        case 2000000: return speed_t(B2000000)
        default: return speed_t(B38400)
        }
    }
    #endif

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
        if n < 0 {
            if errno == EAGAIN { return Data() }
            throw TransportError.readFailed(String(cString: strerror(errno)))
        }
        return Data(buf[0..<n])
    }

    /// Lists candidate adapter device nodes (macOS `/dev/cu.*`, Linux `/dev/ttyUSB*`, `/dev/rfcomm*`).
    public static func availablePorts() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let prefixes = ["cu.usbserial", "cu.usbmodem", "cu.SLAB", "cu.wchusbserial", "cu.OBD", "cu.OBDLink",
                        "cu.Bluetooth-Incoming-Port", "ttyUSB", "ttyACM", "rfcomm"]
        return entries
            .filter { e in prefixes.contains { e.hasPrefix($0) } && e != "cu.Bluetooth-Incoming-Port" }
            .map { "/dev/" + $0 }
            .sorted()
    }
}

// MARK: - POSIX shims (avoid name clashes with Transport.open/close/read/write)

@inline(__always) func sysOpen(_ path: UnsafePointer<CChar>, _ flags: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.open(path, flags)
    #else
    return Glibc.open(path, flags)
    #endif
}
@inline(__always) func sysClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(fd)
    #else
    return Glibc.close(fd)
    #endif
}
@inline(__always) func sysRead(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ n: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.read(fd, buf, n)
    #else
    return Glibc.read(fd, buf, n)
    #endif
}
@inline(__always) func sysWrite(_ fd: Int32, _ buf: UnsafeRawPointer, _ n: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.write(fd, buf, n)
    #else
    return Glibc.write(fd, buf, n)
    #endif
}

/// Waits until `fd` is readable. Returns false on timeout.
func waitReadable(fd: Int32, timeout: TimeInterval) throws -> Bool {
    var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ms = Int32(max(0, timeout * 1000))
    while true {
        let r = poll(&p, 1, ms)
        if r < 0 {
            if errno == EINTR { continue }
            throw TransportError.readFailed("poll: \(String(cString: strerror(errno)))")
        }
        return r > 0
    }
}
