import Foundation

/// How sure we are about a catalogue entry. Anything below `.high` should be confirmed with a
/// module scan on the real car before you rely on it.
public enum Confidence: String, Codable { case high, medium, low }

public struct FordModule: Hashable, Codable {
    public var acronym: String
    public var name: String
    public var requestID: UInt32
    public var bus: FordBus
    public var confidence: Confidence
    public var responseID: UInt32 { requestID + 8 }

    public init(_ acronym: String, _ name: String, _ id: UInt32, _ bus: FordBus, _ c: Confidence = .high) {
        self.acronym = acronym; self.name = name; self.requestID = id; self.bus = bus; self.confidence = c
    }
}

public enum FordModuleCatalog {
    /// Common Ford module request IDs (11-bit, response = request + 8). Bus placement varies by
    /// platform and model year, which is why `ModuleScanner` probes every bus.
    public static let common: [FordModule] = [
        FordModule("PCM", "Powertrain Control Module", 0x7E0, .hsCAN),
        FordModule("TCM", "Transmission Control Module", 0x7E1, .hsCAN),
        FordModule("ABS", "Anti-lock Brake / Stability Control", 0x760, .hsCAN),
        FordModule("RCM", "Restraints Control Module (airbags)", 0x737, .hsCAN),
        FordModule("PSCM", "Power Steering Control Module", 0x730, .hsCAN),
        FordModule("IPC", "Instrument Panel Cluster", 0x720, .hsCAN, .medium),
        FordModule("BCM", "Body Control Module", 0x726, .hsCAN, .medium),
        FordModule("GWM", "Gateway Module", 0x716, .hsCAN, .medium),
        FordModule("APIM", "SYNC / Accessory Protocol Interface Module", 0x7D0, .msCAN, .medium),
        FordModule("ACM", "Audio Control Module", 0x727, .msCAN, .medium),
        FordModule("HVAC", "Climate Control Module", 0x733, .msCAN, .medium),
        FordModule("DDM", "Driver Door Module", 0x740, .msCAN, .medium),
        FordModule("PDM", "Passenger Door Module", 0x741, .msCAN, .medium),
        FordModule("PAM", "Parking Aid Module", 0x736, .msCAN, .medium),
        FordModule("IPMA", "Image Processing Module A (camera)", 0x706, .hsCAN, .medium),
        FordModule("TCU", "Telematics Control Unit (modem)", 0x754, .hsCAN, .medium),
        FordModule("SCCM", "Steering Column Control Module", 0x724, .hsCAN, .medium),
        FordModule("CCM", "Cruise Control (radar) Module", 0x764, .hsCAN, .medium),
    ]

    /// Mustang Mach-E (CX727, 2021+). BEV-specific IDs come from community PID work
    /// (MachEforum "Extended PIDs for Torque" thread) and are marked medium/low.
    /// Run `fordlink scan` on your car to confirm the real layout.
    public static let machE: [FordModule] = [
        FordModule("BECM", "Battery Energy Control Module (HV battery)", 0x7E4, .hsCAN, .high),
        FordModule("SOBDMC", "Secondary On-Board Diagnostic Module C (charging / HV supervisory)", 0x7E2, .hsCAN, .medium),
        FordModule("PCM", "Powertrain / Vehicle Control (BEV)", 0x7E0, .hsCAN, .medium),
        FordModule("TRCM?", "Drive / gear control (answers 'gear commanded')", 0x7E6, .hsCAN, .low),
        FordModule("DCCM?", "DC fast-charge related module (0x6F5, unverified name)", 0x6F5, .hsCAN, .low),
        FordModule("ABS", "Anti-lock Brake / Stability Control", 0x760, .hsCAN, .medium),
        FordModule("RCM", "Restraints Control Module", 0x737, .hsCAN, .medium),
        FordModule("PSCM", "Power Steering Control Module", 0x730, .hsCAN, .medium),
        FordModule("GWM", "Gateway Module", 0x716, .hsCAN, .medium),
        FordModule("BCM", "Body Control Module", 0x726, .hsCANPins3_11, .low),
        FordModule("IPC", "Instrument Panel Cluster", 0x720, .hsCANPins3_11, .low),
        FordModule("APIM", "SYNC 4A head unit", 0x7D0, .hsCANPins3_11, .low),
    ]

    public static func label(for id: UInt32, machE: Bool) -> FordModule? {
        (machE ? Self.machE : []).first { $0.requestID == id } ?? common.first { $0.requestID == id }
    }
}

/// VIN helpers.
public enum VIN {
    /// Mach-E VINs start with 3FMTK (Cuautitlán-built Ford MPV, "TK" = Mach-E line).
    /// Medium confidence — also accept an explicit user override in the UI.
    public static func isMachE(_ vin: String) -> Bool { vin.uppercased().hasPrefix("3FMTK") }

    public static func modelYear(_ vin: String) -> Int? {
        guard vin.count == 17 else { return nil }
        let c = vin[vin.index(vin.startIndex, offsetBy: 9)]
        let codes = Array("ABCDEFGHJKLMNPRSTVWXY123456789")
        guard let i = codes.firstIndex(of: c) else { return nil }
        return 2010 + i // A=2010 … Y=2030 cycle; fine for current Fords
    }

    public static func isValid(_ vin: String) -> Bool {
        vin.count == 17 && vin.allSatisfy { $0.isLetter || $0.isNumber } && !vin.contains { "IOQ".contains($0) }
    }
}
