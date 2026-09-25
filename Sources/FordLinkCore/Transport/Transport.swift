import Foundation

/// Errors raised by any adapter transport.
public enum TransportError: Error, CustomStringConvertible, Equatable {
    case openFailed(String)
    case notOpen
    case writeFailed(String)
    case readFailed(String)
    case timeout
    case configurationFailed(String)

    public var description: String {
        switch self {
        case .openFailed(let s): return "Could not open adapter: \(s)"
        case .notOpen: return "Adapter connection is not open"
        case .writeFailed(let s): return "Write failed: \(s)"
        case .readFailed(let s): return "Read failed: \(s)"
        case .timeout: return "Timed out waiting for adapter"
        case .configurationFailed(let s): return "Port configuration failed: \(s)"
        }
    }
}

/// A byte pipe to an OBD adapter (USB serial, Wi-Fi TCP, Bluetooth LE, or simulator).
///
/// Transports are synchronous and blocking; call them off the main thread.
public protocol Transport: AnyObject {
    var name: String { get }
    var isOpen: Bool { get }
    func open() throws
    func close()
    func write(_ data: Data) throws
    /// Reads whatever bytes are available, waiting up to `timeout` seconds for the first byte.
    /// Returns empty data on timeout.
    func read(timeout: TimeInterval) throws -> Data
    /// Change line speed (serial only; others ignore it).
    func setBaudRate(_ baud: Int) throws
}

public extension Transport {
    func setBaudRate(_ baud: Int) throws {}
}

/// How the user described the adapter connection.
public enum AdapterEndpoint: Equatable, CustomStringConvertible {
    case serial(path: String, baud: Int)
    case tcp(host: String, port: UInt16)
    case bluetoothLE(nameOrUUID: String)
    case simulator(VehicleSimulator.Profile)

    public var description: String {
        switch self {
        case .serial(let p, let b): return "serial \(p) @ \(b)"
        case .tcp(let h, let p): return "wifi \(h):\(p)"
        case .bluetoothLE(let n): return "ble \(n)"
        case .simulator(let p): return "simulator (\(p.rawValue))"
        }
    }

    /// Parse user strings such as `/dev/cu.usbserial-1234`, `serial:/dev/cu.x@115200`,
    /// `tcp:192.168.0.10:35000`, `wifi` (default ELM Wi-Fi address), `ble:OBDLink CX`, `sim:mache`.
    public static func parse(_ raw: String) -> AdapterEndpoint? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s == "wifi" { return .tcp(host: "192.168.0.10", port: 35000) }
        if s.hasPrefix("sim") {
            let rest = s.split(separator: ":").dropFirst().first.map(String.init) ?? "mache"
            return .simulator(VehicleSimulator.Profile(rawValue: rest) ?? .machE)
        }
        if s.hasPrefix("tcp:") || s.hasPrefix("wifi:") {
            let body = s.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
            let parts = body.split(separator: ":")
            guard let host = parts.first else { return nil }
            let port = parts.count > 1 ? UInt16(parts[1]) ?? 35000 : 35000
            return .tcp(host: String(host), port: port)
        }
        if s.hasPrefix("ble:") { return .bluetoothLE(nameOrUUID: String(s.dropFirst(4))) }
        var path = s
        if path.hasPrefix("serial:") { path = String(path.dropFirst(7)) }
        guard path.hasPrefix("/") else { return nil }
        if let at = path.lastIndex(of: "@"), let baud = Int(path[path.index(after: at)...]) {
            return .serial(path: String(path[..<at]), baud: baud)
        }
        return .serial(path: path, baud: 0) // 0 = auto-detect
    }

    public func makeTransport() -> Transport {
        switch self {
        case .serial(let p, let b): return SerialTransport(path: p, baud: b == 0 ? 38400 : b)
        case .tcp(let h, let p): return TCPTransport(host: h, port: p)
        case .bluetoothLE(let n): return makeBLETransport(nameOrUUID: n)
        case .simulator(let p): return VehicleSimulator(profile: p)
        }
    }
}
