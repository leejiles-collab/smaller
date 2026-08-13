import Foundation
import Compression

/// PDF `/FlateDecode` encoding.
///
/// Apple's `Compression` framework emits *raw* DEFLATE (RFC 1951); PDF expects
/// a zlib stream (RFC 1950), so we bolt on the two-byte header and the Adler-32
/// trailer ourselves. No third-party zlib involved.
enum Flate {

    /// Returns nil when compression fails or does not pay for itself.
    static func encode(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }

        let capacity = input.count + (input.count / 2) + 64
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { dst.deallocate() }

        let written = input.withUnsafeBytes { src -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(dst, capacity, base, input.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }

        var out = Data(capacity: written + 6)
        out.append(contentsOf: [0x78, 0x9C])                 // zlib header, default compression
        out.append(dst, count: written)
        var adler = adler32(input).bigEndian
        withUnsafeBytes(of: &adler) { out.append(contentsOf: $0) }

        // If the "compressed" form is bigger, the caller should store it plain.
        return out.count < input.count ? out : nil
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        let modulus: UInt32 = 65521
        data.withUnsafeBytes { raw in
            // Chunked so the modulo only runs every 5552 bytes (NMAX).
            var i = 0
            let count = raw.count
            while i < count {
                let end = min(i + 5552, count)
                while i < end {
                    a &+= UInt32(raw[i])
                    b &+= a
                    i += 1
                }
                a %= modulus
                b %= modulus
            }
        }
        return (b << 16) | a
    }
}
