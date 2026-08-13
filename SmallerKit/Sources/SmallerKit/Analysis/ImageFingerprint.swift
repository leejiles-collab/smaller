import Foundation
import CoreGraphics
import CryptoKit

/// Content identity for image XObjects.
///
/// Object identity is useless here: a PowerPoint export embeds the same header
/// banner once per slide as a separate object every time. Only hashing the
/// bytes finds those, and finding them is the single cheapest win available —
/// it costs no quality at all.
enum ImageFingerprint {

    /// SHA-256 over the stream bytes plus every dictionary field that changes
    /// how those bytes are read. Two images sharing a fingerprint are the same
    /// picture presented the same way, so one copy can serve both.
    static func identity(data: Data, descriptor: String, maskDigest: String?) -> ImageIdentity {
        var hasher = SHA256()
        hasher.update(data: data)
        hasher.update(data: Data(descriptor.utf8))
        if let maskDigest { hasher.update(data: Data(maskDigest.utf8)) }
        return ImageIdentity(hex: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The dictionary fields that affect interpretation of the samples.
    static func descriptor(dict: CGPDFDictionaryRef) -> String {
        var parts: [String] = []
        for key in ["Width", "Height", "BitsPerComponent"] {
            var value: CGPDFInteger = 0
            if CGPDFDictionaryGetInteger(dict, key, &value) { parts.append("\(key)=\(value)") }
        }
        var colorSpaceObject: CGPDFObjectRef?
        CGPDFDictionaryGetObject(dict, "ColorSpace", &colorSpaceObject)
        let space = ColorSpaceInfo.parse(colorSpaceObject)
        parts.append("cs=\(space.name)/\(space.componentCount)")
        parts.append("filter=\(FilterChain.names(from: dict).joined(separator: "+"))")

        var isMask = false
        CGPDFDictionaryGetBoolean(dict, "ImageMask", &isMask)
        parts.append("imagemask=\(isMask)")

        var decode: CGPDFArrayRef?
        parts.append("decode=\(CGPDFDictionaryGetArray(dict, "Decode", &decode))")
        return parts.joined(separator: ";")
    }

    /// Reads a stream's bytes. Returns nil when CoreGraphics cannot give them
    /// to us at all, which is the one case we must not paper over.
    static func read(stream: CGPDFStreamRef) -> (data: Data, format: CGPDFDataFormat)? {
        var format = CGPDFDataFormat.raw
        guard let cfData = CGPDFStreamCopyData(stream, &format) else { return nil }
        return (cfData as Data, format)
    }

    /// Full identity for an image, reading both the image and its mask.
    /// Used by the inventory; the rebuilder computes it from bytes it already
    /// has in hand.
    static func compute(stream: CGPDFStreamRef, dict: CGPDFDictionaryRef) -> ImageIdentity? {
        guard let (data, _) = read(stream: stream) else { return nil }
        return identity(
            data: data,
            descriptor: descriptor(dict: dict),
            maskDigest: maskDigest(imageDict: dict)
        )
    }

    /// Digest of the attached soft mask, or nil when there is none.
    static func maskDigest(imageDict: CGPDFDictionaryRef) -> String? {
        guard let (stream, dict, _) = maskStream(imageDict: imageDict) else { return nil }
        guard let (data, _) = read(stream: stream) else { return "unreadable" }
        return digest(data) + "|" + descriptor(dict: dict)
    }

    /// Finds the mask attached to an image: an 8-bit `/SMask`, or a 1-bit
    /// `/Mask` stencil. A `/Mask` given as an array is colour-key masking and
    /// is reported separately, because it cannot survive re-encoding.
    static func maskStream(imageDict: CGPDFDictionaryRef) -> (CGPDFStreamRef, CGPDFDictionaryRef, isStencil: Bool)? {
        var soft: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(imageDict, "SMask", &soft), let soft,
           let dict = CGPDFStreamGetDictionary(soft) {
            return (soft, dict, false)
        }
        var stencil: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(imageDict, "Mask", &stencil), let stencil,
           let dict = CGPDFStreamGetDictionary(stencil) {
            return (stencil, dict, true)
        }
        return nil
    }

    /// True when `/Mask` is an array of sample ranges rather than a stencil.
    static func hasColourKeyMask(imageDict: CGPDFDictionaryRef) -> Bool {
        var array: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(imageDict, "Mask", &array)
    }

    static func describeMask(imageDict: CGPDFDictionaryRef) -> MaskInfo? {
        guard let (_, dict, isStencil) = maskStream(imageDict: imageDict) else { return nil }

        var width: CGPDFInteger = 0
        var height: CGPDFInteger = 0
        CGPDFDictionaryGetInteger(dict, "Width", &width)
        CGPDFDictionaryGetInteger(dict, "Height", &height)

        var bpc: CGPDFInteger = 8
        if !CGPDFDictionaryGetInteger(dict, "BitsPerComponent", &bpc) { bpc = isStencil ? 1 : 8 }

        var length: CGPDFInteger = 0
        CGPDFDictionaryGetInteger(dict, "Length", &length)

        var matte: CGPDFArrayRef?
        var decode: CGPDFArrayRef?
        return MaskInfo(
            pixelWidth: Int(width),
            pixelHeight: Int(height),
            bitsPerComponent: Int(bpc),
            encodedLength: Int(length),
            hasMatte: CGPDFDictionaryGetArray(dict, "Matte", &matte),
            hasDecodeArray: CGPDFDictionaryGetArray(dict, "Decode", &decode),
            isStencil: isStencil
        )
    }
}
