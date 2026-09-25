import Foundation

/// One CAN frame as printed by an ELM327 with headers on (ATH1).
public struct CANFrame: Equatable {
    public var id: UInt32
    public var data: [UInt8]
    public init(id: UInt32, data: [UInt8]) { self.id = id; self.data = data }

    /// Parse one ELM output line such as `7EC 10 14 62 48 01 00 00` or `18 DA F1 10 03 41 0D 00`.
    /// Returns nil for status lines (`NO DATA`, `SEARCHING...`, `CAN ERROR`, ...).
    public static func parse(line: String) -> CANFrame? {
        let tokens = line.split(whereSeparator: { $0 == " " }).map(String.init)
        guard !tokens.isEmpty, tokens.allSatisfy({ $0.allSatisfy(\.isHexDigit) }) else { return nil }
        if tokens[0].count == 3, let id = UInt32(tokens[0], radix: 16) {
            let data = tokens.dropFirst().compactMap { UInt8($0, radix: 16) }
            return data.isEmpty ? nil : CANFrame(id: id, data: data)
        }
        // Spaces off (ATS0): "7EC0662480100" — 11-bit header then bytes
        if tokens.count == 1, tokens[0].count >= 5, tokens[0].count % 2 == 1 {
            let t = tokens[0]
            guard let id = UInt32(t.prefix(3), radix: 16), let data = Hex.bytes(String(t.dropFirst(3))) else { return nil }
            return CANFrame(id: id, data: data)
        }
        // 29-bit: 4 header bytes then data
        if tokens.count >= 5, tokens.prefix(4).allSatisfy({ $0.count == 2 }) {
            guard let id = UInt32(tokens.prefix(4).joined(), radix: 16) else { return nil }
            return CANFrame(id: id, data: tokens.dropFirst(4).compactMap { UInt8($0, radix: 16) })
        }
        return nil
    }
}

/// Reassembles ISO 15765-2 (ISO-TP) messages from raw frames, per CAN ID.
public struct ISOTPAssembler {
    public struct Message: Equatable {
        public var id: UInt32
        public var payload: [UInt8]
    }

    private struct Partial { var expected: Int; var data: [UInt8]; var nextSeq: UInt8 }
    private var partial: [UInt32: Partial] = [:]
    public private(set) var messages: [Message] = []

    public init() {}

    public mutating func feed(_ f: CANFrame) {
        guard let pci = f.data.first else { return }
        switch pci >> 4 {
        case 0x0: // single frame
            var len = Int(pci & 0x0F)
            var start = 1
            if len == 0, f.data.count > 1 { len = Int(f.data[1]); start = 2 } // CAN-FD escape
            let body = Array(f.data.dropFirst(start).prefix(len))
            messages.append(Message(id: f.id, payload: body))
        case 0x1: // first frame
            guard f.data.count >= 2 else { return }
            let len = (Int(pci & 0x0F) << 8) | Int(f.data[1])
            partial[f.id] = Partial(expected: len, data: Array(f.data.dropFirst(2)), nextSeq: 1)
        case 0x2: // consecutive frame
            guard var p = partial[f.id] else { return }
            let seq = pci & 0x0F
            guard seq == p.nextSeq else { partial[f.id] = nil; return } // lost frame: drop message
            p.data += f.data.dropFirst()
            p.nextSeq = (p.nextSeq + 1) & 0x0F
            if p.data.count >= p.expected {
                messages.append(Message(id: f.id, payload: Array(p.data.prefix(p.expected))))
                partial[f.id] = nil
            } else {
                partial[f.id] = p
            }
        default: // 0x3 flow control — ignore
            break
        }
    }
}
