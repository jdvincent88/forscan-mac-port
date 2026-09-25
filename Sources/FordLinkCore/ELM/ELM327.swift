import Foundation

public enum ELMError: Error, CustomStringConvertible, Equatable {
    case noPrompt(String)
    case unsupportedCommand(String)
    case noData
    case busError(String)
    case unexpected(String)

    public var description: String {
        switch self {
        case .noPrompt(let s): return "Adapter did not return a prompt (got: \(s.isEmpty ? "nothing" : s))"
        case .unsupportedCommand(let c): return "Adapter does not support \(c)"
        case .noData: return "No response from vehicle module"
        case .busError(let s): return "CAN bus problem: \(s)"
        case .unexpected(let s): return "Unexpected adapter reply: \(s)"
        }
    }
}

/// Which physical CAN bus / pins we are talking on.
public enum FordBus: String, CaseIterable, Codable, CustomStringConvertible {
    /// HS-CAN1, OBD pins 6/14, 500 kbps. Powertrain, BECM, ABS, legislated OBD.
    case hsCAN = "HS-CAN"
    /// MS-CAN, OBD pins 3/11, 125 kbps. Body / comfort on most 2005-2019 Fords.
    case msCAN = "MS-CAN"
    /// HS-CAN on pins 3/11 at 500 kbps (called HS-CAN2/HS-CAN3 by FORScan on 2015+ platforms,
    /// including Mach-E). Needs an adapter with a second transceiver on pins 3/11.
    case hsCANPins3_11 = "HS-CAN (pins 3/11)"

    public var description: String { rawValue }
    public var pins: String { self == .hsCAN ? "6/14" : "3/11" }
    public var kbps: Int { self == .msCAN ? 125 : 500 }
}

/// Low-level ELM327 / STN command interpreter.
public final class ELM327 {
    public let transport: Transport
    public var log: ((String) -> Void)?
    public private(set) var currentHeader: UInt32?
    public private(set) var currentBus: FordBus?
    public var isSTN = false

    public init(transport: Transport) {
        self.transport = transport
    }

    // MARK: Raw command I/O

    /// Sends a command and returns cleaned response lines (without echo, blank lines and prompt).
    @discardableResult
    public func send(_ command: String, timeout: TimeInterval = 3) throws -> [String] {
        try drain()
        log?("> \(command)")
        try transport.write(Data((command + "\r").utf8))
        let raw = try readUntilPrompt(timeout: timeout)
        var lines = raw
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
            .split(separator: "\r")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Strip echo if ATE0 not yet applied
        if let first = lines.first, first.replacingOccurrences(of: " ", with: "").uppercased()
            == command.replacingOccurrences(of: " ", with: "").uppercased() {
            lines.removeFirst()
        }
        for l in lines { log?("< \(l)") }
        return lines
    }

    /// Sends an AT/ST command that should reply OK. Throws `unsupportedCommand` on `?`.
    public func expectOK(_ command: String, timeout: TimeInterval = 3) throws {
        let r = try send(command, timeout: timeout)
        if r.contains("?") { throw ELMError.unsupportedCommand(command) }
        guard r.contains(where: { $0.uppercased().hasSuffix("OK") }) else {
            throw ELMError.unexpected("\(command) -> \(r.joined(separator: " | "))")
        }
    }

    /// Returns true if the adapter accepted the command (anything but `?`).
    public func supports(_ command: String) -> Bool {
        guard let r = try? send(command) else { return false }
        return !r.isEmpty && !r.contains("?")
    }

    private func drain() throws {
        while !(try transport.read(timeout: 0.01)).isEmpty {}
    }

    private func readUntilPrompt(timeout: TimeInterval) throws -> String {
        var acc = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let chunk = try transport.read(timeout: min(0.2, max(0.01, deadline.timeIntervalSinceNow)))
            if chunk.isEmpty { continue }
            acc.append(chunk)
            if acc.contains(UInt8(ascii: ">")) {
                let s = String(decoding: acc.filter { $0 != 0 }, as: UTF8.self)
                return String(s[..<s.firstIndex(of: ">")!])
            }
        }
        throw ELMError.noPrompt(String(decoding: acc, as: UTF8.self))
    }

    // MARK: Setup

    /// Reset and apply the base configuration used for Ford diagnostics.
    public func reset() throws {
        _ = try? send("ATWS", timeout: 3) // warm start; some clones only honour ATZ
        _ = try send("ATZ", timeout: 5)
        try expectOK("ATE0")
        _ = try? send("ATL0")
        _ = try? send("ATS1")       // keep spaces: simpler, unambiguous parsing
        try expectOK("ATH1")        // headers on: we do ISO-TP reassembly ourselves
        _ = try? send("ATAT1")      // adaptive timing
        isSTN = (try? send("STI"))?.first.map { !$0.contains("?") } ?? false
        currentHeader = nil
        currentBus = nil
    }

    /// Select one of the Ford CAN buses.
    ///
    /// * OBDLink (STN) adapters: `STP 33` (HS-CAN) / `STP 53` (MS-CAN, pins 3/11), baud via `STPBR`.
    ///   Protocol numbers from the OBDLink Family Reference and Programming Manual.
    /// * Plain ELM327 with a manual HS/MS switch: HS-CAN uses `ATSP6`; the 3/11 buses use
    ///   user protocol B (`ATPB 81 xx`, 11-bit, DLC=8, ISO 15765, 500k/xx) and the switch must be
    ///   flipped by hand — software cannot tell.
    public func selectBus(_ bus: FordBus) throws {
        if currentBus == bus { return }
        if isSTN {
            switch bus {
            case .hsCAN:
                try expectOK("STP 33")
            case .msCAN:
                try expectOK("STP 53")
            case .hsCANPins3_11:
                try expectOK("STP 53")
                try expectOK("STPBR 500000")
            }
        } else {
            switch bus {
            case .hsCAN:
                try expectOK("ATSP6")
            case .msCAN:
                try expectOK("ATPB 81 04") // 500/4 = 125 kbps
                try expectOK("ATSPB")
            case .hsCANPins3_11:
                try expectOK("ATPB 81 01") // 500/1 = 500 kbps
                try expectOK("ATSPB")
            }
        }
        _ = try? send("ATCAF1")
        currentBus = bus
        currentHeader = nil
    }

    /// Point requests at a module (11-bit ID). Responses are filtered to `tx + 8` (Ford/ISO convention)
    /// unless `rx` is given. Passing 0x7DF sets the functional broadcast and clears the filter.
    public func setTarget(tx: UInt32, rx: UInt32? = nil) throws {
        if currentHeader == tx { return }
        try expectOK("ATSH \(Hex.id(tx))")
        if tx == 0x7DF {
            _ = try? send("ATCRA")           // no filter
            if isSTN { _ = try? send("STCFCPC") } // clear custom flow-control
        } else {
            let r = rx ?? (tx + 8)
            try expectOK("ATCRA \(Hex.id(r))")
            // Flow-control frames must go to the module's request ID when using CAN auto-formatting.
            _ = try? send("ATFCSH \(Hex.id(tx))")
            _ = try? send("ATFCSD 30 00 00")
            _ = try? send("ATFCSM 1")
        }
        currentHeader = tx
    }

    /// Sends a diagnostic request (service + data, no PCI) and returns reassembled responses.
    public func request(_ payload: [UInt8], timeout: TimeInterval = 3) throws -> [ISOTPAssembler.Message] {
        let lines = try send(Hex.string(payload), timeout: timeout)
        if let err = lines.first(where: { Self.isBusError($0) }) { throw ELMError.busError(err) }
        var asm = ISOTPAssembler()
        for l in lines { if let f = CANFrame.parse(line: l) { asm.feed(f) } }
        if asm.messages.isEmpty {
            if lines.contains(where: { $0.contains("NO DATA") || $0.contains("STOPPED") }) || lines.isEmpty {
                throw ELMError.noData
            }
            if lines.contains("?") { throw ELMError.unexpected("adapter rejected request \(Hex.string(payload))") }
        }
        return asm.messages
    }

    static func isBusError(_ line: String) -> Bool {
        ["CAN ERROR", "BUS ERROR", "BUS BUSY", "UNABLE TO CONNECT", "FB ERROR", "DATA ERROR", "LV RESET"]
            .contains { line.uppercased().contains($0) }
    }
}
