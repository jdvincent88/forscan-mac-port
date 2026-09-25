import Foundation

/// An in-process ELM327/STN emulator with simulated Ford modules.
///
/// Used for unit tests and so the app can be explored without a car or adapter
/// (`fordlink setup sim:mache`). Behaviour follows the ELM327 / OBDLink manuals closely enough
/// to exercise the real code paths (echo, prompts, headers, ISO-TP multi-frame, NRCs).
public final class VehicleSimulator: Transport {
    public enum Profile: String, CaseIterable, Codable {
        /// OBDLink EX (STN2232, MS-CAN capable) plugged into a 2022 Mach-E.
        case machE = "mache"
        /// Cheap ELM327 "v2.1" clone plugged into a Mach-E: no ATPB, no pins 3/11.
        case machEClone = "mache-clone"
        /// OBDLink EX with the ignition off / no vehicle: adapter answers, modules don't.
        case noVehicle = "novehicle"
    }

    struct ECU {
        var dids: [UInt16: [UInt8]]
        var dtcs: [[UInt8]] // 4 bytes each: DTC hi, mid, lo, status
    }

    public let profile: Profile
    public var name: String { "Simulator (\(profile.rawValue))" }
    public private(set) var isOpen = false

    private var out = Data()
    private var inBuf = ""
    private var echo = true
    private var headers = false
    private var header: UInt32 = 0x7DF
    private var bus: FordBus? = nil
    private var pbDivisor: UInt8 = 1
    private var stnProto: Int?
    private var stnBaud = 125_000
    private var ecus: [FordBus: [UInt32: ECU]] = [:]
    /// Toggle to simulate a module that answers 0x78 (response pending) first.
    public var pendingFirst: Set<UInt32> = []

    public init(profile: Profile) {
        self.profile = profile
        buildVehicle()
    }

    private var isSTN: Bool { profile != .machEClone }

    private func buildVehicle() {
        guard profile != .noVehicle else { return }
        let vin = Array("3FMTK3SU5MMA12345".utf8)
        func soc(_ pct: Double) -> [UInt8] { let v = UInt16(pct / 0.002); return [UInt8(v >> 8), UInt8(v & 0xFF)] }
        let becm = ECU(dids: [
            0xF190: vin,
            0xF188: Array("NU5T-14C197-AB".utf8),
            0x4801: soc(78.4),
            0x4845: [UInt8(80 * 2)],
            0x4800: [74],             // 24 °C
            0x4808: [77, 72, 5, 74],
            0x4840: [0x0F, 0x3C],          // 3.900 V
            0x4841: [0x0F, 0x46],          // 3.910 V
            0x4813: [0x9C, 0x40],          // 1000 kΩ
            0x4848: [0x7A, 0x12],
            0x4850: [0x00, 0x00],
        ], dtcs: [[0xC1, 0x00, 0x00, 0x09]]) // U0100-00 (lost comm with PCM), history
        let sobdmc = ECU(dids: [
            0xF190: vin,
            0x480D: [0x8C, 0xA0],          // 360.00 V
            0x480B: [0xFF, 0x06],          // -250 * 0.02 = -5.00 A (charging)
            0x484D: [0x00], 0x4851: [0x00],
            0x484A: [0x00, 0x00], 0x484E: [0x00, 0x00], 0x48C4: [0x00, 0x00],
            0xD117: [65], 0xD00C: [65],
            0xDD04: [62], 0xDD05: [70],
        ], dtcs: [])
        let pcm = ECU(dids: [0xF190: vin], dtcs: [[0x0A, 0x7F, 0x00, 0x08]]) // P0A7F-00
        let abs = ECU(dids: [0xF190: vin], dtcs: [])
        let gwm = ECU(dids: [0xF190: vin], dtcs: [])
        let bcm = ECU(dids: [0xF190: vin, 0xF188: Array("LJ8T-14F013-EF".utf8)], dtcs: [[0x9A, 0x03, 0x11, 0x2F]])
        let ipc = ECU(dids: [0xF190: vin], dtcs: [])
        ecus[.hsCAN] = [0x7E4: becm, 0x7E2: sobdmc, 0x7E0: pcm, 0x760: abs, 0x716: gwm]
        ecus[.hsCANPins3_11] = [0x726: bcm, 0x720: ipc]
    }

    public func open() throws { isOpen = true; out.removeAll(); inBuf = "" }
    public func close() { isOpen = false }

    public func write(_ data: Data) throws {
        guard isOpen else { throw TransportError.notOpen }
        inBuf += String(decoding: data, as: UTF8.self)
        while let r = inBuf.firstIndex(of: "\r") {
            let cmd = String(inBuf[..<r])
            inBuf = String(inBuf[inBuf.index(after: r)...])
            handle(cmd)
        }
    }

    public func read(timeout: TimeInterval) throws -> Data {
        guard isOpen else { throw TransportError.notOpen }
        let d = out
        out.removeAll()
        return d
    }

    // MARK: Command handling

    private func reply(_ lines: [String]) {
        out.append(Data((lines.joined(separator: "\r") + "\r\r>").utf8))
    }

    private func handle(_ rawCmd: String) {
        if echo { out.append(Data((rawCmd + "\r").utf8)) }
        let cmd = rawCmd.uppercased().replacingOccurrences(of: " ", with: "")
        if cmd.isEmpty { reply([]); return }
        if cmd.hasPrefix("AT") { reply(at(String(cmd.dropFirst(2)))); return }
        if cmd.hasPrefix("ST") { reply(st(String(cmd.dropFirst(2)))); return }
        guard let bytes = Hex.bytes(cmd), !bytes.isEmpty else { reply(["?"]); return }
        reply(obd(bytes))
    }

    private func at(_ c: String) -> [String] {
        switch c {
        case "Z", "WS":
            echo = true; headers = false; header = 0x7DF; bus = nil; stnProto = nil
            return ["", isSTN ? "ELM327 v1.4b" : "ELM327 v2.1"]
        case "I": return [isSTN ? "ELM327 v1.4b" : "ELM327 v2.1"]
        case "@1": return [isSTN ? "OBDLink EX" : "OBDII to RS232 Interpreter"]
        case "E0": echo = false; return ["OK"]
        case "E1": echo = true; return ["OK"]
        case "H0": headers = false; return ["OK"]
        case "H1": headers = true; return ["OK"]
        case "RV": return ["12.6V"]
        case "SP6": bus = .hsCAN; stnProto = nil; return ["OK"]
        case "SPB":
            bus = pbDivisor == 4 ? .msCAN : .hsCANPins3_11
            // A clone has no second transceiver: it transmits on pins 6/14 at 125/500k.
            if !isSTN { bus = pbDivisor == 1 ? .hsCAN : nil }
            return ["OK"]
        case "CRA": return ["OK"]
        default: break
        }
        if c.hasPrefix("PB") {
            if !isSTN { return ["?"] } // typical cheap clone
            pbDivisor = UInt8(c.suffix(2), radix: 16) ?? 1
            return ["OK"]
        }
        if c.hasPrefix("SH"), let h = Hex.uint32(String(c.dropFirst(2))) { header = h; return ["OK"] }
        if c.hasPrefix("CRA") || c.hasPrefix("FCSH") || c.hasPrefix("FCSD") || c.hasPrefix("FCSM") {
            return isSTN || c.hasPrefix("CRA") ? ["OK"] : ["?"]
        }
        if ["L0", "L1", "S0", "S1", "AT1", "AT2", "CAF1", "CAF0", "D", "ST FF"].contains(c) || c.hasPrefix("ST") { return ["OK"] }
        return ["?"]
    }

    private func st(_ c: String) -> [String] {
        guard isSTN else { return ["?"] }
        switch c {
        case "I": return ["STN2232 v5.10.3"]
        case "DI": return ["OBDLink EX r1.0"]
        case "P33": stnProto = 33; bus = .hsCAN; return ["OK"]
        case "P53": stnProto = 53; stnBaud = 125_000; bus = .msCAN; return ["OK"]
        case "CFCPC": return ["OK"]
        default: break
        }
        if c.hasPrefix("PBR"), let b = Int(c.dropFirst(3)) {
            stnBaud = b
            if stnProto == 53 { bus = b >= 500_000 ? .hsCANPins3_11 : .msCAN }
            return ["OK"]
        }
        return ["?"]
    }

    private func obd(_ req: [UInt8]) -> [String] {
        guard let bus, let ecu = ecus[bus]?[header] else {
            return bus == nil ? ["CAN ERROR"] : ["NO DATA"]
        }
        let rx = header + 8
        var responses: [[UInt8]] = []
        if pendingFirst.contains(header) { responses.append([0x7F, req[0], 0x78]) }
        responses.append(respond(ecu, req))
        return responses.flatMap { frames(id: rx, payload: $0) }
    }

    private func respond(_ ecu: ECU, _ req: [UInt8]) -> [UInt8] {
        switch req[0] {
        case 0x3E: return [0x7E, req.count > 1 ? req[1] : 0]
        case 0x22:
            guard req.count == 3 else { return [0x7F, 0x22, 0x13] }
            let did = UInt16(req[1]) << 8 | UInt16(req[2])
            guard let v = ecu.dids[did] else { return [0x7F, 0x22, 0x31] }
            return [0x62, req[1], req[2]] + v
        case 0x19:
            guard req.count >= 3, req[1] == 0x02 else { return [0x7F, 0x19, 0x12] }
            return [0x59, 0x02, 0xFF] + ecu.dtcs.flatMap { $0 }
        case 0x14: return [0x54]
        case 0x10: return [0x50, req.count > 1 ? req[1] : 1, 0x00, 0x32, 0x01, 0xF4]
        default: return [0x7F, req[0], 0x11]
        }
    }

    /// Segment a payload as ISO-TP frames and print them the way ELM327 does with ATH1.
    private func frames(id: UInt32, payload: [UInt8]) -> [String] {
        func line(_ d: [UInt8]) -> String {
            let padded = d + [UInt8](repeating: 0x00, count: max(0, 8 - d.count))
            return headers ? Hex.id(id) + " " + Hex.string(padded) : Hex.string(padded)
        }
        if payload.count <= 7 { return [line([UInt8(payload.count)] + payload)] }
        var lines = [line([0x10 | UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + payload.prefix(6))]
        var rest = Array(payload.dropFirst(6))
        var seq: UInt8 = 1
        while !rest.isEmpty {
            lines.append(line([0x20 | seq] + rest.prefix(7)))
            rest = Array(rest.dropFirst(7))
            seq = (seq + 1) & 0x0F
        }
        return lines
    }
}
