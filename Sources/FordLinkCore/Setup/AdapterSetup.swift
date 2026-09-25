import Foundation

/// What kind of adapter we found, ranked by usefulness for Ford / FORScan work.
public enum AdapterClass: String, Codable {
    /// OBDLink EX / MX+ / MX Wi-Fi: STN chip with a second transceiver on pins 3/11.
    case stnWithMSCAN = "OBDLink-class, HS + MS-CAN (best for Ford)"
    /// STN chip without MS-CAN (OBDLink SX, CX, LX): HS-CAN only.
    case stnHSOnly = "STN (OBDLink) — HS-CAN only"
    /// ELM327 (or good clone) supporting programmable protocol B: MS-CAN via manual switch.
    case elmSwitchable = "ELM327 with ATPB support — needs HS/MS switch for pins 3/11"
    /// Cheap clone missing commands FORScan needs.
    case poorClone = "Limited ELM327 clone — HS-CAN OBD only"
    case unknown = "Unknown"
}

public struct AdapterReport: Codable {
    public var endpoint: String
    public var baud: Int?
    public var elmVersion: String = ""
    public var stnVersion: String?
    public var deviceName: String?
    public var voltage: Double?
    public var supported: [String: Bool] = [:]
    public var adapterClass: AdapterClass = .unknown
    public var buses: [String: [String]] = [:]   // bus -> responding module IDs
    public var vin: String?
    public var isMachE = false
    public var modelYear: Int?
    public var warnings: [String] = []
    public var recommendations: [String] = []

    public var usableBuses: [FordBus] {
        switch adapterClass {
        case .stnWithMSCAN: return FordBus.allCases
        case .elmSwitchable: return [.hsCAN, .msCAN, .hsCANPins3_11]
        default: return [.hsCAN]
        }
    }

    public func summary() -> String {
        var s: [String] = []
        s.append("Adapter:     \(deviceName ?? "?")  [\(elmVersion)\(stnVersion.map { " / " + $0 } ?? "")]")
        s.append("Connection:  \(endpoint)\(baud.map { " @ \($0) baud" } ?? "")")
        s.append("Class:       \(adapterClass.rawValue)")
        if let v = voltage { s.append(String(format: "12V at DLC:  %.1f V", v)) }
        s.append("Commands:    " + supported.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value ? "yes" : "NO")" }.joined(separator: "  "))
        if let vin { s.append("VIN:         \(vin)\(modelYear.map { " (MY \($0))" } ?? "")\(isMachE ? "  → Mustang Mach-E" : "")") }
        for (b, ids) in buses.sorted(by: { $0.key < $1.key }) {
            s.append("\(b.padding(toLength: 19, withPad: " ", startingAt: 0)) \(ids.isEmpty ? "no modules answered" : ids.joined(separator: ", "))")
        }
        for w in warnings { s.append("⚠︎  \(w)") }
        for r in recommendations { s.append("→  \(r)") }
        return s.joined(separator: "\n")
    }
}

/// Step-by-step adapter bring-up and Ford compatibility check.
public final class AdapterSetup {
    public let endpoint: AdapterEndpoint
    public var progress: ((String) -> Void)?
    public var trace: ((String) -> Void)?
    public private(set) var elm: ELM327?

    public static let serialBaudCandidates = [38400, 115200, 500000, 9600, 230400, 2000000]

    /// Modules pinged per bus during the quick check (a full sweep is `ModuleScanner`).
    static let quickProbe: [UInt32] = [0x7E0, 0x7E4, 0x7E2, 0x760, 0x716, 0x726, 0x720, 0x7D0, 0x727, 0x733]

    public init(endpoint: AdapterEndpoint) { self.endpoint = endpoint }

    /// Opens the adapter (auto-detecting serial baud rate) and resets it. Returns the live ELM327.
    public func connect() throws -> (ELM327, Int?) {
        var baudFound: Int?
        let transport: Transport
        if case .serial(let path, let baud) = endpoint {
            let candidates = baud == 0 ? Self.serialBaudCandidates : [baud]
            let t = SerialTransport(path: path, baud: candidates[0])
            progress?("Opening \(path)…")
            try t.open()
            let probe = ELM327(transport: t)
            for b in candidates {
                progress?("Trying \(b) baud…")
                try t.setBaudRate(b)
                if let r = try? probe.send("ATI", timeout: 1.5), r.contains(where: { $0.contains("ELM") || $0.contains("STN") }) {
                    baudFound = b
                    break
                }
            }
            guard baudFound != nil else {
                t.close()
                throw ELMError.noPrompt("no ELM327 answer at \(candidates.map(String.init).joined(separator: "/")) baud")
            }
            transport = t
        } else {
            transport = endpoint.makeTransport()
            progress?("Connecting to \(transport.name)…")
            try transport.open()
        }
        let e = ELM327(transport: transport)
        e.log = trace
        progress?("Resetting adapter…")
        try e.reset()
        elm = e
        return (e, baudFound)
    }

    /// Full wizard: identify adapter, test Ford-relevant capabilities, probe each bus, read VIN.
    public func run() throws -> AdapterReport {
        let (e, baud) = try connect()
        var rep = AdapterReport(endpoint: endpoint.description, baud: baud)

        progress?("Identifying adapter…")
        rep.elmVersion = (try? e.send("ATI"))?.last ?? "?"
        rep.deviceName = (try? e.send("AT@1"))?.last.flatMap { $0 == "?" ? nil : $0 }
        if e.isSTN {
            rep.stnVersion = (try? e.send("STI"))?.last
            if let di = (try? e.send("STDI"))?.last, di != "?" { rep.deviceName = di }
        }
        if let v = (try? e.send("ATRV"))?.last, let d = Double(v.filter { "0123456789.".contains($0) }) {
            rep.voltage = d
        }

        progress?("Testing Ford-specific commands…")
        rep.supported["ATPB (programmable CAN)"] = e.supports("ATPB 81 04")
        rep.supported["ATCRA (rx filter)"] = e.supports("ATCRA 7E8")
        rep.supported["ATFCSH (flow control)"] = e.supports("ATFCSH 7E0")
        if e.isSTN { rep.supported["STP 53 (MS-CAN pins 3/11)"] = e.supports("STP 53") }
        _ = try? e.send("ATCRA")
        rep.adapterClass = classify(e, rep)

        // Probe each bus the adapter can reach.
        for bus in rep.usableBuses {
            if bus != .hsCAN && rep.adapterClass == .elmSwitchable {
                rep.warnings.append("\(bus): switched adapter — results only valid if the HS/MS switch was set to MS. Re-run with it flipped if nothing answered.")
            }
            progress?("Probing \(bus) (pins \(bus.pins), \(bus.kbps) kbps)…")
            var found: [String] = []
            do {
                try e.selectBus(bus)
                let uds = UDSClient(elm: e)
                for id in Self.quickProbe where uds.ping(module: id, bus: bus) {
                    found.append(Hex.id(id))
                    if rep.vin == nil, let v = try? uds.readASCII(module: id, bus: bus, did: FordDID.vin), VIN.isValid(v) {
                        rep.vin = v
                    }
                }
            } catch {
                rep.warnings.append("\(bus): \(error)")
            }
            rep.buses[bus.rawValue] = found
        }

        // Fall back to legislated OBD-II VIN (mode 09 PID 02) on HS-CAN.
        if rep.vin == nil, (try? e.selectBus(.hsCAN)) != nil, (try? e.setTarget(tx: 0x7DF)) != nil,
           let msgs = try? e.request([0x09, 0x02]),
           let m = msgs.first(where: { $0.payload.first == 0x49 }) {
            let v = String(decoding: m.payload.dropFirst(3).filter { $0 >= 0x30 }, as: UTF8.self)
            if VIN.isValid(v) { rep.vin = v }
        }

        if let vin = rep.vin {
            rep.isMachE = VIN.isMachE(vin)
            rep.modelYear = VIN.modelYear(vin)
        }
        addAdvice(&rep)
        progress?("Done.")
        return rep
    }

    func classify(_ e: ELM327, _ rep: AdapterReport) -> AdapterClass {
        let pb = rep.supported["ATPB (programmable CAN)"] ?? false
        let cra = rep.supported["ATCRA (rx filter)"] ?? false
        if e.isSTN {
            let ms = rep.supported["STP 53 (MS-CAN pins 3/11)"] ?? false
            let name = (rep.deviceName ?? "").uppercased()
            if ms || name.contains("EX") || name.contains("MX") { return .stnWithMSCAN }
            return .stnHSOnly
        }
        if pb && cra { return .elmSwitchable }
        return .poorClone
    }

    func addAdvice(_ rep: inout AdapterReport) {
        if let v = rep.voltage, v < 12.2 {
            rep.warnings.append(String(format: "12V supply is %.1f V. Connect a 12V maintainer before long sessions or any module programming.", v))
        }
        let anyModule = rep.buses.values.contains { !$0.isEmpty }
        if !anyModule {
            rep.warnings.append("No modules answered. Turn ignition ON (Mach-E: press brake + power button until 'Ready' or accessory mode), check the adapter is fully seated.")
        }
        switch rep.adapterClass {
        case .stnWithMSCAN:
            rep.recommendations.append("This adapter is FORScan's top-tier recommendation class. In FORScan choose the adapter's COM port; it switches HS/MS automatically.")
        case .stnHSOnly:
            rep.recommendations.append("HS-CAN only: fine for battery/powertrain data, but body modules on pins 3/11 are unreachable. For full Ford access use OBDLink EX (USB) or MX+ (Bluetooth).")
        case .elmSwitchable:
            rep.recommendations.append("Switched ELM327: works with FORScan, but you must flip HS/MS when FORScan prompts. OBDLink EX removes that step.")
        case .poorClone, .unknown:
            rep.recommendations.append("This clone lacks commands FORScan uses (ATPB/flow control). Expect OBD-II only. Replace with OBDLink EX or vLinker FS USB for Ford work.")
        }
        if rep.isMachE {
            rep.recommendations.append("Mach-E detected. HV battery data lives on HS-CAN (BECM 7E4, SOBDMC 7E2) — try `fordlink live … --mache`.")
            rep.recommendations.append("Mach-E body modules (BCM, IPC, SYNC 4A) sit behind the gateway on pins 3/11 at 500 kbps; only adapters with a second transceiver reach them.")
            rep.recommendations.append("For module configuration/programming use FORScan (Windows) via Parallels/VMware or CrossOver — see docs/FORSCAN_ON_MAC.md. Keep a 12V maintainer on the car.")
        }
    }
}

/// Sweeps 11-bit diagnostic IDs on every bus to find which modules the car really has.
public final class ModuleScanner {
    public let uds: UDSClient
    public var progress: ((Double, String) -> Void)?

    public struct Found: Identifiable, Codable {
        public var id: String { "\(bus.rawValue)-\(Hex.id(requestID))" }
        public var bus: FordBus
        public var requestID: UInt32
        public var label: String
        public var partNumber: String?
        public var vin: String?
    }

    public init(uds: UDSClient) { self.uds = uds }

    public func scan(buses: [FordBus], range: ClosedRange<UInt32> = 0x700...0x7EF, machE: Bool) -> [Found] {
        var found: [Found] = []
        let ids = Array(range).filter { $0 != 0x7DF }
        let total = Double(ids.count * buses.count)
        var n = 0.0
        for bus in buses {
            guard (try? uds.elm.selectBus(bus)) != nil else { continue }
            _ = try? uds.elm.send("ATST 19") // ~100 ms per-probe timeout keeps the sweep quick
            for id in ids {
                n += 1
                progress?(n / total, "\(bus) \(Hex.id(id))")
                // Skip response IDs of modules already found (they can alias as requests).
                if found.contains(where: { $0.requestID + 8 == id }) { continue }
                guard uds.ping(module: id, bus: bus) else { continue }
                let m = FordModuleCatalog.label(for: id, machE: machE)
                found.append(Found(
                    bus: bus, requestID: id,
                    label: m.map { "\($0.acronym) — \($0.name)" } ?? "Unknown module",
                    partNumber: try? uds.readASCII(module: id, bus: bus, did: FordDID.softwarePartNumber),
                    vin: try? uds.readASCII(module: id, bus: bus, did: FordDID.vin)))
            }
            _ = try? uds.elm.send("ATST FF")
        }
        return found
    }
}
