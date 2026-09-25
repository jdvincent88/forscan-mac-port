import Foundation

public enum Hex {
    /// "7E4" -> 0x7E4, "18DAF110" -> 0x18DAF110
    public static func uint32(_ s: String) -> UInt32? { UInt32(s.replacingOccurrences(of: " ", with: ""), radix: 16) }

    /// "22 48 01" or "224801" -> [0x22, 0x48, 0x01]
    public static func bytes(_ s: String) -> [UInt8]? {
        let clean = s.filter { !$0.isWhitespace }
        guard clean.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(clean.count / 2)
        var i = clean.startIndex
        while i < clean.endIndex {
            let j = clean.index(i, offsetBy: 2)
            guard let b = UInt8(clean[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    public static func string(_ bytes: [UInt8], separator: String = " ") -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: separator)
    }

    public static func id(_ v: UInt32) -> String {
        v > 0x7FF ? String(format: "%08X", v) : String(format: "%03X", v)
    }
}
