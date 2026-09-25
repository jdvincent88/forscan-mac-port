import Foundation

/// A manufacturer-specific live-data item read with UDS 0x22.
public struct FordPID: Identifiable {
    public var id: String { "\(Hex.id(module))-\(String(format: "%04X", did))-\(name)" }
    public var name: String
    public var module: UInt32
    public var bus: FordBus
    public var did: UInt16
    public var unit: String
    public var confidence: Confidence
    /// Decodes the bytes following the echoed DID (A = bytes[0], B = bytes[1], ...).
    public var decode: ([UInt8]) -> Double?

    public init(_ name: String, module: UInt32, bus: FordBus = .hsCAN, did: UInt16, unit: String,
                confidence: Confidence = .medium, decode: @escaping ([UInt8]) -> Double?) {
        self.name = name; self.module = module; self.bus = bus; self.did = did
        self.unit = unit; self.confidence = confidence; self.decode = decode
    }
}

// Formula helpers mirroring Torque/Car Scanner notation.
@inline(__always) func A(_ b: [UInt8]) -> Double? { b.count > 0 ? Double(b[0]) : nil }
@inline(__always) func B(_ b: [UInt8]) -> Double? { b.count > 1 ? Double(b[1]) : nil }
@inline(__always) func u16(_ b: [UInt8], _ i: Int = 0) -> Double? {
    b.count > i + 1 ? Double(UInt16(b[i]) << 8 | UInt16(b[i + 1])) : nil
}
@inline(__always) func s16(_ b: [UInt8], _ i: Int = 0) -> Double? {
    b.count > i + 1 ? Double(Int16(bitPattern: UInt16(b[i]) << 8 | UInt16(b[i + 1]))) : nil
}
@inline(__always) func cToF(_ c: Double) -> Double { c * 1.8 + 32 }

/// Mustang Mach-E enhanced PIDs.
///
/// Source: community reverse-engineering, MachEforum thread
/// "Ford Mustang Mach-E Extended PIDs for Torque Project" (formulas reproduced as posted).
/// Headers left blank in that thread are assigned to BECM (0x7E4) for battery items and
/// SOBDMC (0x7E2) for charger items — those are marked `.low`. Verify on your car.
public enum MachEPIDs {
    static let becm: UInt32 = 0x7E4
    static let sobdmc: UInt32 = 0x7E2

    public static let all: [FordPID] = [
        FordPID("HV battery SoC (raw)", module: becm, did: 0x4801, unit: "%", confidence: .high) { u16($0).map { $0 * 0.002 } },
        FordPID("HV battery SoC (displayed)", module: becm, did: 0x4845, unit: "%", confidence: .high) { A($0).map { $0 * 0.5 } },
        FordPID("HV battery voltage", module: sobdmc, did: 0x480D, unit: "V") { u16($0).map { $0 * 0.01 } },
        FordPID("HV battery current", module: sobdmc, did: 0x480B, unit: "A") { s16($0).map { $0 * 0.02 } },
        FordPID("HV battery temperature", module: becm, did: 0x4800, unit: "°F", confidence: .low) { A($0).map { cToF($0 - 50) } },
        FordPID("HV battery max cell-group temp", module: becm, did: 0x4808, unit: "°F", confidence: .low) { A($0).map { cToF($0 - 50) } },
        FordPID("HV battery min cell-group temp", module: becm, did: 0x4808, unit: "°F", confidence: .low) { B($0).map { cToF($0 - 50) } },
        FordPID("HV battery min module voltage", module: becm, did: 0x4840, unit: "V") { u16($0).map { $0 * 0.001 } },
        FordPID("HV battery avg module voltage", module: becm, did: 0x4841, unit: "V") { u16($0).map { $0 * 0.001 } },
        FordPID("HV energy to empty", module: becm, did: 0x4848, unit: "kWh", confidence: .low) { u16($0).map { $0 * 0.002 } },
        FordPID("HV battery age", module: becm, did: 0x4810, unit: "months", confidence: .low) { u16($0).map { $0 * 0.005 } },
        FordPID("HV isolation resistance", module: becm, did: 0x4813, unit: "kΩ") { u16($0).map { $0 * 0.025 } },
        FordPID("HV coolant inlet temp", module: becm, did: 0x4846, unit: "°F", confidence: .low) { A($0).map { cToF($0 - 50) } },
        FordPID("Charger output voltage", module: sobdmc, did: 0x484A, unit: "V") { u16($0).map { $0 * 0.01 } },
        FordPID("Charger output current", module: becm, did: 0x4850, unit: "A") { u16($0).map { $0 * 0.01 } },
        FordPID("Charger input power available", module: sobdmc, did: 0x484E, unit: "kW") { u16($0).map { $0 * 0.005 } },
        FordPID("Charger max power", module: sobdmc, did: 0x48C4, unit: "kW") { u16($0).map { $0 * 0.05 } },
        FordPID("Charger status", module: sobdmc, did: 0x484D, unit: "state") { A($0) },
        FordPID("EVSE type", module: sobdmc, did: 0x4851, unit: "state") { A($0) },
        FordPID("AC charger input voltage", module: sobdmc, did: 0x485E, unit: "V", confidence: .low) { u16($0).map { $0 * 0.01 } },
        FordPID("AC charger input current", module: sobdmc, did: 0x485F, unit: "A", confidence: .low) { A($0) },
        FordPID("Charge pilot duty cycle", module: sobdmc, did: 0x4861, unit: "%", confidence: .low) { A($0).map { $0 * 0.5 } },
        FordPID("AC charge-port temperature", module: sobdmc, did: 0xD117, unit: "°F") { A($0).map { cToF($0 - 40) } },
        FordPID("DC charge-port temperature", module: sobdmc, did: 0xD00C, unit: "°F") { A($0).map { cToF($0 - 40) } },
        FordPID("Cabin temperature", module: sobdmc, did: 0xDD04, unit: "°F") { A($0).map { cToF($0 - 40) } },
        FordPID("Outside temperature", module: sobdmc, did: 0xDD05, unit: "°F") { A($0).map { cToF($0 - 40) } },
    ]

    /// Small set for a dashboard / quick health check.
    public static let dashboard: [String] = [
        "HV battery SoC (displayed)", "HV battery SoC (raw)", "HV battery voltage", "HV battery current",
        "HV battery temperature", "HV isolation resistance", "Charger status", "Outside temperature",
    ]
}

/// Reads PIDs and derives battery power.
public final class LiveDataReader {
    public let uds: UDSClient
    public init(uds: UDSClient) { self.uds = uds }

    public struct Reading: Identifiable {
        public var id: String { pid.id }
        public var pid: FordPID
        public var value: Double?
        public var error: String?
        public var formatted: String {
            if let v = value {
                if pid.unit == "state" { return String(format: "%.0f", v) }
                return String(format: v.magnitude >= 100 ? "%.1f %@" : "%.2f %@", v, pid.unit)
            }
            guard let error else { return "—" }
            if error.contains("NRC 0x31") { return "not supported on this vehicle/software" }
            return error
        }
    }

    public func read(_ pids: [FordPID]) -> [Reading] {
        // Group by (module, DID) so shared DIDs (e.g. 0x4808 min/max) are fetched once.
        var cache: [String: Result<[UInt8], Error>] = [:]
        return pids.map { pid in
            let key = "\(pid.module)-\(pid.did)"
            let res = cache[key] ?? Result { try uds.readDID(module: pid.module, bus: pid.bus, did: pid.did) }
            cache[key] = res
            switch res {
            case .success(let b): return Reading(pid: pid, value: pid.decode(b), error: nil)
            case .failure(let e): return Reading(pid: pid, value: nil, error: "\(e)")
            }
        }
    }

    /// HV power in kW (positive = discharge), from voltage × current.
    public static func batteryPowerKW(_ readings: [Reading]) -> Double? {
        guard let v = readings.first(where: { $0.pid.name == "HV battery voltage" })?.value,
              let a = readings.first(where: { $0.pid.name == "HV battery current" })?.value else { return nil }
        return v * a / 1000
    }
}
