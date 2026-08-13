import Foundation

/// How a page is built, which decides which compression strategy may touch it.
public enum PageClass: String, Sendable, Hashable, CaseIterable {
    /// One image covering >= 85% of the page, with little or no text drawing.
    /// Safe to rasterize wholesale.
    case scanLike
    /// Text and/or vector art alongside images. Rasterizing these is
    /// catastrophic, so only the images inside them may be touched.
    case mixed
    /// No images at all. Nothing for us to do.
    case vectorOnly
}

/// Identity for an image XObject that survives being looked up twice.
///
/// CoreGraphics gives no stable handle for an indirect object, and hashing every
/// image's bytes during inventory would mean decoding the whole document just to
/// count it. The encoded length plus the pixel geometry is specific enough: two
/// images that collide here are the same picture in all but pathological cases,
/// and the cost of a collision is one image downsampled to a slightly different
/// resolution — never a corrupt file.
public struct ImageKey: Sendable, Hashable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let bitsPerComponent: Int
    public let encodedLength: Int
    public let filter: String
}

/// One image XObject as it is actually used on a page.
public struct ImageUsage: Sendable, Hashable {
    public let key: ImageKey
    public let pageIndex: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let bitsPerComponent: Int
    public let componentCount: Int
    public let colorSpaceName: String
    public let filter: ImageFilter
    /// Raw stream length in bytes — what this image actually costs in the file.
    public let rawByteLength: Int
    /// Size the image is drawn at, in PDF points, after the full CTM.
    public let drawnWidthPoints: Double
    public let drawnHeightPoints: Double
    /// True when the image carries alpha (`/SMask` or `/Mask`) or is a stencil.
    public let hasAlpha: Bool
    public let isStencilMask: Bool

    /// Effective resolution the image is presented at.
    public var effectiveDPI: Double {
        guard drawnWidthPoints > 0.01 else { return 0 }
        return Double(pixelWidth) / (drawnWidthPoints / 72.0)
    }

    /// Fraction of the page area this image covers.
    public func coverage(ofPageArea area: Double) -> Double {
        guard area > 0.01 else { return 0 }
        return (drawnWidthPoints * drawnHeightPoints) / area
    }

    /// 1-bit fax/line art. Already tiny; rasterizing it makes it bigger.
    public var isBilevel: Bool { bitsPerComponent == 1 }

    /// Whether the engine is willing to re-encode this image at all.
    public var isRecodable: Bool {
        !isBilevel && !hasAlpha && !isStencilMask && filter.isDecodable && componentCount >= 1
    }
}

public enum ImageFilter: String, Sendable, Hashable {
    case dct = "DCTDecode"          // JPEG
    case flate = "FlateDecode"      // PNG-ish
    case lzw = "LZWDecode"
    case jpx = "JPXDecode"          // JPEG 2000
    case ccitt = "CCITTFaxDecode"   // fax / bilevel scan
    case jbig2 = "JBIG2Decode"
    case runLength = "RunLengthDecode"
    case none = "None"
    case other = "Other"

    /// Whether we can get pixels back out of it with ImageIO / CoreGraphics.
    public var isDecodable: Bool {
        switch self {
        case .dct, .flate, .lzw, .runLength, .none, .jpx: true
        case .ccitt, .jbig2, .other: false
        }
    }
}

/// Per-page summary produced by the scanner.
public struct PageSummary: Sendable, Hashable {
    public let index: Int
    public let widthPoints: Double
    public let heightPoints: Double
    public let rotation: Int
    public let pageClass: PageClass
    public let textOperatorCount: Int
    public let imageCount: Int
    public let imageBytes: Int
    /// Largest coverage fraction of any single image on the page.
    public let maxImageCoverage: Double
}

/// Everything the engine learned about a document in one parse.
public struct PDFInventory: Sendable {
    public let url: URL
    public let byteSize: Int
    public let pageCount: Int
    public let pages: [PageSummary]
    public let images: [ImageUsage]
    public let isEncrypted: Bool
    public let hasFormFields: Bool
    public let hasEmbeddedText: Bool
    /// Bytes in the file attributable to image streams.
    public let imageBytes: Int
    /// Predicted output size per preset profile, derived from the images above.
    public let estimatedSizes: [CompressionProfile: Int]

    public var imageCount: Int { images.count }

    public var pageClasses: [PageClass] { pages.map(\.pageClass) }

    /// Everything that is not an image stream: text, fonts, vector art, structure.
    public var nonImageBytes: Int { max(0, byteSize - imageBytes) }

    public var imageByteFraction: Double {
        guard byteSize > 0 else { return 0 }
        return Double(imageBytes) / Double(byteSize)
    }

    public var pageClassMix: [PageClass: Int] {
        pages.reduce(into: [:]) { $0[$1.pageClass, default: 0] += 1 }
    }

    /// Below this share of the file, squeezing images cannot meaningfully help
    /// and the honest answer is "this one's already small".
    public static let worthwhileImageFraction = 0.20

    public var isWorthCompressing: Bool {
        imageByteFraction >= Self.worthwhileImageFraction
    }

    /// Images the engine will decline to touch, with a reason. Surfaced in the
    /// CLI report so the skip rate is visible per fixture.
    public var skippedImages: [ImageUsage] { images.filter { !$0.isRecodable } }
}
