import Foundation

public enum UDSError: Error, CustomStringConvertible, Equatable {
    case negativeResponse(service: UInt8, code: UInt8)
    case noResponse(module: UInt32)
    case malformed(String)

    public var description: String {
        switch self {
        case .negativeResponse(let s, let c):
            return String(format: "Module refused service 0x%02X: %@ (NRC 0x%02X)", s, UDSClient.nrcText(c), c)
        case .noResponse(let m): return "No response from module \(Hex.id(m))"
        case .malformed(let s): return "Malformed response: \(s)"
        }
    }
}

/// A decoded diagnostic trouble code.
public struct DTC: Equatable, CustomStringConvertible {
    public var raw: UInt32       // 3-byte UDS DTC (or 2-byte OBD DTC << 8)
    public var status: UInt8
    public var code: String      // e.g. "P0A7F-00"

    public var description: String { "\(code)  status=\(String(format: "%02X", status))\(flags.isEmpty ? "" : " [" + flags.joined(separator: ", ") + "]")" }

    public var flags: [String] {
        var f: [String] = []
        if status & 0x01 != 0 { f.append("failed now") }
        if status & 0x04 != 0 { f.append("pending") }
        if status & 0x08 != 0 { f.append("confirmed") }
        if status & 0x80 != 0 { f.append("warning lamp") }
        return f
    }

    /// Formats the first 2 bytes as P/C/B/U code and the third as the Ford failure-type byte.
    public static func format(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8?) -> String {
        let letters = ["P", "C", "B", "U"]
        let base = letters[Int(b0 >> 6)] + String(format: "%01X%01X%02X", (b0 >> 4) & 0x3, b0 & 0x0F, b1)
        if let b2 { return base + String(format: "-%02X", b2) }
        return base
    }
}

/// Unified Diagnostic Services (ISO 14229) over the ELM327 link.
public final class UDSClient {
    public let elm: ELM327
    public init(elm: ELM327) { self.elm = elm }

    /// Sends a request to a physical module and returns the positive response payload
    /// (starting with the positive-response SID, i.e. service + 0x40).
    public func call(module: UInt32, bus: FordBus, _ request: [UInt8], timeout: TimeInterval = 3) throws -> [UInt8] {
        try elm.selectBus(bus)
        try elm.setTarget(tx: module)
        let rxID = module + 8
        for attempt in 0..<3 {
            let msgs: [ISOTPAssembler.Message]
            do { msgs = try elm.request(request, timeout: timeout) }
            catch ELMError.noData { throw UDSError.noResponse(module: module) }
            let mine = msgs.filter { $0.id == rxID }.map(\.payload)
            // Final answer = last non-"response pending" message
            let final = mine.last { !($0.count >= 3 && $0[0] == 0x7F && $0[2] == 0x78) }
            if let r = final {
                if r.first == 0x7F, r.count >= 3 { throw UDSError.negativeResponse(service: r[1], code: r[2]) }
                guard r.first == request[0] &+ 0x40 else { throw UDSError.malformed(Hex.string(r)) }
                return r
            }
            if mine.isEmpty { throw UDSError.noResponse(module: module) }
            // Only 0x78 pending seen: module still working, ask again (safe for read services).
            if attempt < 2 { usleep(300_000) }
        }
        throw UDSError.noResponse(module: module)
    }

    /// Service 0x22 ReadDataByIdentifier. Returns the data bytes after the echoed DID.
    public func readDID(module: UInt32, bus: FordBus, did: UInt16) throws -> [UInt8] {
        let r = try call(module: module, bus: bus, [0x22, UInt8(did >> 8), UInt8(did & 0xFF)])
        guard r.count >= 3, r[1] == UInt8(did >> 8), r[2] == UInt8(did & 0xFF) else {
            throw UDSError.malformed(Hex.string(r))
        }
        return Array(r.dropFirst(3))
    }

    public func readASCII(module: UInt32, bus: FordBus, did: UInt16) throws -> String {
        let b = try readDID(module: module, bus: bus, did: did)
        return String(decoding: b.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Service 0x3E TesterPresent — cheap "are you there?" probe for module discovery.
    public func ping(module: UInt32, bus: FordBus) -> Bool {
        (try? call(module: module, bus: bus, [0x3E, 0x00], timeout: 1.5)) != nil
    }

    /// Service 0x19 sub 0x02 (report DTCs by status mask 0xFF). Read-only.
    public func readDTCs(module: UInt32, bus: FordBus) throws -> [DTC] {
        let r = try call(module: module, bus: bus, [0x19, 0x02, 0xFF])
        return Self.parseDTCs(r)
    }

    static func parseDTCs(_ r: [UInt8]) -> [DTC] {
        // 59 02 <availabilityMask> [DTC_HI DTC_MID DTC_LO STATUS]...
        guard r.count >= 3 else { return [] }
        var out: [DTC] = []
        var i = 3
        while i + 4 <= r.count {
            let (a, b, c, s) = (r[i], r[i + 1], r[i + 2], r[i + 3])
            let raw = UInt32(a) << 16 | UInt32(b) << 8 | UInt32(c)
            if raw != 0 { out.append(DTC(raw: raw, status: s, code: DTC.format(a, b, c))) }
            i += 4
        }
        return out
    }

    /// Service 0x14 ClearDiagnosticInformation (all groups). Writes to the vehicle.
    public func clearDTCs(module: UInt32, bus: FordBus) throws {
        _ = try call(module: module, bus: bus, [0x14, 0xFF, 0xFF, 0xFF], timeout: 5)
    }

    public static func nrcText(_ c: UInt8) -> String {
        switch c {
        case 0x10: return "general reject"
        case 0x11: return "service not supported"
        case 0x12: return "sub-function not supported"
        case 0x13: return "incorrect message length"
        case 0x22: return "conditions not correct"
        case 0x31: return "request out of range (DID not supported)"
        case 0x33: return "security access denied"
        case 0x35: return "invalid key"
        case 0x7E: return "sub-function not supported in active session"
        case 0x7F: return "service not supported in active session"
        default: return "negative response"
        }
    }
}

/// Standard identifiers Ford modules answer on service 0x22.
public enum FordDID {
    public static let vin: UInt16 = 0xF190
    public static let partNumber: UInt16 = 0xF111        // Ford: ECU core assembly number
    public static let softwarePartNumber: UInt16 = 0xF188
    public static let calibrationLevel: UInt16 = 0xF124  // strategy / calibration
    public static let hardwarePartNumber: UInt16 = 0xF113
}
