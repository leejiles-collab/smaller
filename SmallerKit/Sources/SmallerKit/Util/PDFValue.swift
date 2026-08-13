import Foundation

/// A PDF object, in the small subset we need to *write*.
///
/// Reading is done with CoreGraphics' `CGPDF*` API; this type only exists so we
/// can serialize a document back out with some image streams swapped.
indirect enum PDFValue {
    case null
    case bool(Bool)
    case integer(Int)
    case real(Double)
    case name(String)
    /// Always emitted as a hex string, which sidesteps every escaping question.
    case string([UInt8])
    case array([PDFValue])
    case dictionary([String: PDFValue])
    case reference(Int)

    static func size(_ v: Int) -> PDFValue { .integer(v) }
}

extension PDFValue {
    /// Serialized bytes, appended to `out`.
    func write(to out: inout [UInt8]) {
        switch self {
        case .null:
            out.append(contentsOf: Array("null".utf8))

        case .bool(let b):
            out.append(contentsOf: Array((b ? "true" : "false").utf8))

        case .integer(let i):
            out.append(contentsOf: Array(String(i).utf8))

        case .real(let d):
            out.append(contentsOf: Array(PDFValue.format(d).utf8))

        case .name(let n):
            out.append(0x2F) // '/'
            out.append(contentsOf: PDFValue.escapeName(n))

        case .string(let bytes):
            out.append(0x3C) // '<'
            for b in bytes {
                out.append(PDFValue.hexDigits[Int(b >> 4)])
                out.append(PDFValue.hexDigits[Int(b & 0x0F)])
            }
            out.append(0x3E) // '>'

        case .array(let items):
            out.append(0x5B) // '['
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(0x20) }
                item.write(to: &out)
            }
            out.append(0x5D) // ']'

        case .dictionary(let dict):
            out.append(contentsOf: Array("<<".utf8))
            // Sorted so identical dictionaries serialize identically, which is
            // what makes content-hash de-duplication work.
            for key in dict.keys.sorted() {
                out.append(0x2F)
                out.append(contentsOf: PDFValue.escapeName(key))
                out.append(0x20)
                dict[key]!.write(to: &out)
            }
            out.append(contentsOf: Array(">>".utf8))

        case .reference(let n):
            out.append(contentsOf: Array("\(n) 0 R".utf8))
        }
    }

    var serialized: [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        write(to: &out)
        return out
    }

    // MARK: - Encoding details

    private static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

    /// PDF has no exponent notation, so `%g` is not safe here.
    static func format(_ d: Double) -> String {
        guard d.isFinite else { return "0" }
        if d == d.rounded() && abs(d) < 1e15 {
            return String(Int(d))
        }
        var s = String(format: "%.6f", d)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s.isEmpty ? "0" : s
    }

    /// Name objects escape anything outside the regular character set as `#xx`.
    static func escapeName(_ name: String) -> [UInt8] {
        var out: [UInt8] = []
        for b in Array(name.utf8) {
            let isRegular = b > 0x20 && b < 0x7F
                && b != 0x23 // #
                && b != 0x2F // /
                && b != 0x28 && b != 0x29 // ( )
                && b != 0x3C && b != 0x3E // < >
                && b != 0x5B && b != 0x5D // [ ]
                && b != 0x7B && b != 0x7D // { }
                && b != 0x25 // %
            if isRegular {
                out.append(b)
            } else {
                out.append(0x23)
                out.append(hexDigits[Int(b >> 4)])
                out.append(hexDigits[Int(b & 0x0F)])
            }
        }
        return out
    }
}

/// Cheap, stable content hash used to spot two identical images or two
/// identical resource dictionaries.
enum FNV1a {
    static func hash(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }

    static func hash(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { hash($0) }
    }

    static func hash(_ bytes: [UInt8]) -> UInt64 {
        bytes.withUnsafeBytes { hash($0) }
    }
}
