import Foundation
import CoreGraphics

/// Counts image objects by reading the file's bytes directly, with no help from
/// CoreGraphics.
///
/// This exists because every other measurement we take comes through
/// `CGPDFDocument`, and on a file with a damaged cross-reference table
/// CoreGraphics resolves some objects and not others — without ever saying so.
/// Comparing what it hands us against what is demonstrably in the file is the
/// only way to know whether its view is complete.
///
/// It is sound to do this in plain bytes: an image XObject carries stream data,
/// so its dictionary can never be tucked inside a compressed object stream. The
/// `/Subtype /Image` marker is always there in the clear.
enum RawCensus {

    /// Number of `/Subtype /Image` dictionaries physically present in the file.
    /// Includes soft masks, which are image XObjects in their own right.
    static func imageObjectCount(url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }

        let subtype = Array("/Subtype".utf8)
        let image = Array("/Image".utf8)
        var count = 0

        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let end = raw.count
            var i = 0
            while i + subtype.count < end {
                guard base[i] == 0x2F else { i += 1; continue }  // '/'
                guard matches(base, at: i, subtype, limit: end) else { i += 1; continue }

                // Skip whitespace between "/Subtype" and its value.
                var j = i + subtype.count
                while j < end, isWhitespace(base[j]) { j += 1 }

                if matches(base, at: j, image, limit: end) {
                    // Guard against "/ImageMask" and "/ImageB" style names.
                    let after = j + image.count
                    if after >= end || !isNameCharacter(base[after]) { count += 1 }
                }
                i = j
            }
        }
        return count
    }

    private static func matches(_ base: UnsafePointer<UInt8>, at index: Int, _ pattern: [UInt8], limit: Int) -> Bool {
        guard index + pattern.count <= limit else { return false }
        for k in pattern.indices where base[index + k] != pattern[k] { return false }
        return true
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 || byte == 0x00 || byte == 0x0C
    }

    /// Regular characters may continue a name token.
    private static func isNameCharacter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
    }

    /// Every image object CoreGraphics can actually reach, found by walking each
    /// page's resources rather than by watching what gets drawn.
    ///
    /// The distinction matters: plenty of ordinary PDFs carry an image that is
    /// present and resolvable but never painted. Counting only painted images
    /// would make those look like objects CoreGraphics had lost, and get a
    /// perfectly good file refused.
    static func reachableImageObjects(document: CGPDFDocument) -> Set<UInt> {
        var found = Set<UInt>()
        for index in 1...max(1, document.numberOfPages) {
            autoreleasepool {
                guard let page = document.page(at: index), let dict = page.dictionary else { return }
                var resources: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources else { return }
                walk(resources: resources, into: &found, depth: 0)
            }
        }
        return found
    }

    private static func walk(resources: CGPDFDictionaryRef, into found: inout Set<UInt>, depth: Int) {
        guard depth < 8 else { return }

        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return }

        // The apply block cannot capture, so collect the names first.
        var names: [String] = []
        withUnsafeMutablePointer(to: &names) { pointer in
            CGPDFDictionaryApplyBlock(xobjects, { key, _, info in
                info!.assumingMemoryBound(to: [String].self).pointee.append(String(cString: key))
                return true
            }, pointer)
        }

        for name in names {
            var stream: CGPDFStreamRef?
            guard CGPDFDictionaryGetStream(xobjects, name, &stream), let stream,
                  let streamDict = CGPDFStreamGetDictionary(stream) else { continue }

            var subtypePtr: UnsafePointer<CChar>?
            CGPDFDictionaryGetName(streamDict, "Subtype", &subtypePtr)
            let subtype = subtypePtr.map { String(cString: $0) } ?? ""

            switch subtype {
            case "Image":
                found.insert(address(stream))
                if let (maskStream, _, _) = ImageFingerprint.maskStream(imageDict: streamDict) {
                    found.insert(address(maskStream))
                }
            case "Form":
                var nested: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(streamDict, "Resources", &nested), let nested {
                    walk(resources: nested, into: &found, depth: depth + 1)
                }
            default:
                break
            }
        }
    }

    private static func address<Pointer>(_ pointer: Pointer) -> UInt {
        UInt(bitPattern: unsafeBitCast(pointer, to: Int.self))
    }
}
