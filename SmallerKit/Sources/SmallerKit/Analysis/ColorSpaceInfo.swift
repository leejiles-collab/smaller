import Foundation
import CoreGraphics

/// What we need to know about an image's `/ColorSpace` entry: what to call it
/// and how many samples per pixel it implies.
struct ColorSpaceInfo {
    let name: String
    let componentCount: Int
    /// Indexed images carry a palette; we expand those ourselves when decoding.
    let isIndexed: Bool
    /// Colorspaces we can rebuild a `CGImage` from when the pixels arrive raw.
    let isRebuildable: Bool

    static let unknown = ColorSpaceInfo(name: "Unknown", componentCount: 0, isIndexed: false, isRebuildable: false)

    static func parse(_ object: CGPDFObjectRef?) -> ColorSpaceInfo {
        guard let object else { return unknown }

        var namePtr: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(object, .name, &namePtr), let namePtr {
            return named(String(cString: namePtr))
        }

        var array: CGPDFArrayRef?
        if CGPDFObjectGetValue(object, .array, &array), let array, CGPDFArrayGetCount(array) > 0 {
            var familyPtr: UnsafePointer<CChar>?
            guard CGPDFArrayGetName(array, 0, &familyPtr), let familyPtr else { return unknown }
            let family = String(cString: familyPtr)

            switch family {
            case "ICCBased":
                var stream: CGPDFStreamRef?
                if CGPDFArrayGetStream(array, 1, &stream), let stream,
                   let dict = CGPDFStreamGetDictionary(stream) {
                    var n: CGPDFInteger = 0
                    if CGPDFDictionaryGetInteger(dict, "N", &n) {
                        return ColorSpaceInfo(
                            name: "ICCBased(\(n))",
                            componentCount: Int(n),
                            isIndexed: false,
                            isRebuildable: n == 1 || n == 3 || n == 4
                        )
                    }
                }
                return ColorSpaceInfo(name: "ICCBased", componentCount: 3, isIndexed: false, isRebuildable: false)

            case "Indexed", "I":
                return ColorSpaceInfo(name: "Indexed", componentCount: 1, isIndexed: true, isRebuildable: true)

            case "CalRGB", "Lab":
                return ColorSpaceInfo(name: family, componentCount: 3, isIndexed: false, isRebuildable: family == "CalRGB")

            case "CalGray":
                return ColorSpaceInfo(name: family, componentCount: 1, isIndexed: false, isRebuildable: true)

            case "Separation":
                return ColorSpaceInfo(name: family, componentCount: 1, isIndexed: false, isRebuildable: false)

            case "DeviceN":
                var names: CGPDFArrayRef?
                let count = CGPDFArrayGetArray(array, 1, &names) ? CGPDFArrayGetCount(names!) : 0
                return ColorSpaceInfo(name: "DeviceN(\(count))", componentCount: count, isIndexed: false, isRebuildable: false)

            case "DeviceGray", "DeviceRGB", "DeviceCMYK":
                return named(family)

            default:
                return ColorSpaceInfo(name: family, componentCount: 0, isIndexed: false, isRebuildable: false)
            }
        }
        return unknown
    }

    private static func named(_ name: String) -> ColorSpaceInfo {
        switch name {
        case "DeviceGray", "G", "CalGray":
            ColorSpaceInfo(name: "DeviceGray", componentCount: 1, isIndexed: false, isRebuildable: true)
        case "DeviceRGB", "RGB", "CalRGB":
            ColorSpaceInfo(name: "DeviceRGB", componentCount: 3, isIndexed: false, isRebuildable: true)
        case "DeviceCMYK", "CMYK":
            ColorSpaceInfo(name: "DeviceCMYK", componentCount: 4, isIndexed: false, isRebuildable: true)
        case "Pattern":
            ColorSpaceInfo(name: "Pattern", componentCount: 0, isIndexed: false, isRebuildable: false)
        default:
            ColorSpaceInfo(name: name, componentCount: 0, isIndexed: false, isRebuildable: false)
        }
    }
}

/// Reads `/Filter`, which may be a bare name or a chain.
enum FilterChain {
    /// Filters CoreGraphics decodes for us before handing back stream data.
    static let standard: Set<String> = [
        "FlateDecode", "Fl", "LZWDecode", "LZW",
        "ASCII85Decode", "A85", "ASCIIHexDecode", "AHx", "RunLengthDecode", "RL"
    ]

    static func names(from dict: CGPDFDictionaryRef, key: String = "Filter") -> [String] {
        var namePtr: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dict, key, &namePtr), let namePtr {
            return [normalize(String(cString: namePtr))]
        }
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dict, key, &array), let array {
            var out: [String] = []
            for i in 0..<CGPDFArrayGetCount(array) {
                var n: UnsafePointer<CChar>?
                if CGPDFArrayGetName(array, i, &n), let n {
                    out.append(normalize(String(cString: n)))
                }
            }
            return out
        }
        return []
    }

    static func normalize(_ name: String) -> String {
        switch name {
        case "Fl": "FlateDecode"
        case "LZW": "LZWDecode"
        case "A85": "ASCII85Decode"
        case "AHx": "ASCIIHexDecode"
        case "RL": "RunLengthDecode"
        case "DCT": "DCTDecode"
        case "CCF": "CCITTFaxDecode"
        default: name
        }
    }

    /// The filter that decides how we treat the image, i.e. the last one in the
    /// chain that is not a generic byte-level codec.
    static func imageFilter(_ names: [String]) -> ImageFilter {
        for name in names.reversed() where !standard.contains(name) {
            return ImageFilter(rawValue: name) ?? .other
        }
        if names.contains("FlateDecode") { return .flate }
        if names.contains("LZWDecode") { return .lzw }
        if names.contains("RunLengthDecode") { return .runLength }
        return names.isEmpty ? .none : .other
    }
}
