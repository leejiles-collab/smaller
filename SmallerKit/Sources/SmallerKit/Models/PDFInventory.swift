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

/// Content identity for an image: SHA-256 over the stream's bytes plus the
/// dictionary fields that change how those bytes are interpreted.
///
/// PowerPoint and Keynote embed the same banner once per slide as separate
/// objects, so identity has to be by *content*, not by object. On a real deck
/// this is the difference between 26 MB of images and 5.9 MB of distinct ones.
public struct ImageIdentity: Sendable, Hashable, CustomStringConvertible {
    public let hex: String
    public init(hex: String) { self.hex = hex }
    public var description: String { String(hex.prefix(12)) }
}

/// Cheap pre-identity used to spot which images are even worth hashing.
public struct ImageKey: Sendable, Hashable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let bitsPerComponent: Int
    public let encodedLength: Int
    public let filter: String
}

/// Why the engine did, or did not, re-encode an image. Every image in the
/// document ends up with exactly one of these, and the CLI prints the tally so
/// the decline list is visible rather than implied.
public enum ImageDecision: Sendable, Hashable {
    /// Re-encoded as JPEG.
    case recoded
    /// Re-encoded as JPEG plus a separate FlateDecode `/SMask`.
    case recodedWithMask
    /// Byte-identical to an image already written; rewritten as a reference.
    case deduplicated
    /// Left exactly as it was, for the stated reason.
    case declined(DeclineReason)
    /// Re-encoding produced something no smaller, so the original was kept.
    case noSmaller

    public var isDecline: Bool {
        if case .declined = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .recoded: "recoded"
        case .recodedWithMask: "recoded+mask"
        case .deduplicated: "deduped"
        case .noSmaller: "no smaller"
        case .declined(let reason): "declined: \(reason.label)"
        }
    }
}

public enum DeclineReason: String, Sendable, Hashable, CaseIterable {
    /// 1-bit line art. Already tiny, and rasterizing it makes it bigger.
    case bilevel
    /// CCITT fax or JBIG2 — no way to get pixels back through ImageIO.
    case undecodableFilter
    /// A colorspace we cannot faithfully rebuild (Separation, DeviceN, Lab).
    case unresolvableColorSpace
    /// Premultiplied alpha. Un-premultiplying is guesswork, so we leave it.
    case matte
    /// A `/Decode` array changes how samples are read; re-encoding would
    /// silently drop it.
    case decodeArray
    /// Colour-key masking: `/Mask` is an array of sample ranges that would stop
    /// meaning anything once the image is re-encoded as JPEG.
    case colourKeyMask
    /// The soft mask itself could not be decoded.
    case maskUndecodable
    /// We never saw it drawn, so we do not know what resolution it needs.
    case neverDrawn
    /// Decoding failed outright.
    case decodeFailed

    public var label: String { rawValue }
}

/// A soft mask attached to an image.
public struct MaskInfo: Sendable, Hashable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let bitsPerComponent: Int
    public let encodedLength: Int
    /// `/Matte` means the base image is premultiplied against this mask.
    public let hasMatte: Bool
    public let hasDecodeArray: Bool
    /// A 1-bit `/Mask` stencil rather than an 8-bit `/SMask`.
    public let isStencil: Bool
}

/// One image XObject as it is actually used on a page.
public struct ImageUsage: Sendable, Hashable {
    public let identity: ImageIdentity
    public let key: ImageKey
    public let pageIndex: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let bitsPerComponent: Int
    public let componentCount: Int
    public let colorSpaceName: String
    public let filter: ImageFilter
    /// Encoded stream length — what this image costs in the file.
    public let rawByteLength: Int
    /// Size the image is drawn at, in PDF points, after the full CTM.
    public let drawnWidthPoints: Double
    public let drawnHeightPoints: Double
    /// Present when the image carries a soft mask or stencil mask.
    public let mask: MaskInfo?
    /// `/Mask` given as an array of sample ranges rather than a stencil.
    public let hasColourKeyMask: Bool
    public let hasDecodeArray: Bool
    /// The image is itself a stencil mask (`/ImageMask true`).
    public let isStencilMask: Bool

    public var hasAlpha: Bool { mask != nil || hasColourKeyMask }

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

    /// 1-bit fax/line art.
    public var isBilevel: Bool { bitsPerComponent == 1 }

    /// Bytes this image and its mask cost together.
    public var totalByteLength: Int { rawByteLength + (mask?.encodedLength ?? 0) }

    /// Why we would refuse this image, or nil if we will take it on.
    ///
    /// Alpha is deliberately *not* a refusal any more: decks export nearly
    /// every graphic as FlateDecode RGB with a soft mask, so declining them
    /// meant declining the entire payload.
    public var declineReason: DeclineReason? {
        if isBilevel || isStencilMask { return .bilevel }
        if !filter.isDecodable { return .undecodableFilter }
        if componentCount < 1 { return .unresolvableColorSpace }
        if hasDecodeArray { return .decodeArray }
        if hasColourKeyMask { return .colourKeyMask }
        if let mask {
            if mask.hasMatte { return .matte }
            if mask.hasDecodeArray { return .decodeArray }
        }
        return nil
    }

    public var isRecodable: Bool { declineReason == nil }
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
    public let isLocked: Bool
    public let hasFormFields: Bool
    public let hasEmbeddedText: Bool
    /// True when the cross-reference table had to be rebuilt to open the file.
    public let xrefWasRepaired: Bool
    /// Image objects physically present in the file, counted without
    /// CoreGraphics. Compared against what CoreGraphics actually resolved, this
    /// is how we find out that its view of a damaged file is incomplete.
    public let rawImageObjectCount: Int
    /// Distinct image stream objects CoreGraphics resolved for us.
    public let resolvedImageObjectCount: Int
    /// Bytes taken by distinct image *objects* — what images cost in the file.
    public let imageObjectBytes: Int
    /// Bytes taken by distinct image *content*. The gap between this and
    /// `imageObjectBytes` is pure waste, recoverable at zero quality cost.
    public let uniqueImageBytes: Int
    /// Image keys that were identified by hashing their pixels, because more
    /// than one object in the document carries that key.
    ///
    /// The rebuilder sees a different `CGPDFDocument` handle and so must derive
    /// identity for itself. It has to make the same choice this parse made for
    /// every image, or its lookups land on nothing — hence the rule travelling
    /// with the inventory rather than being guessed at twice.
    public let contentHashedKeys: Set<ImageKey>
    /// Predicted output size per profile, derived from the images above.
    public let estimatedSizes: [CompressionProfile: Int]

    public var imageCount: Int { images.count }

    public var pageClasses: [PageClass] { pages.map(\.pageClass) }

    /// What images cost in this file.
    public var imageBytes: Int { imageObjectBytes }

    /// Recoverable by rearranging bytes alone, with no quality loss whatsoever.
    public var duplicateImageBytes: Int { max(0, imageObjectBytes - uniqueImageBytes) }

    /// Everything that is not an image stream: text, fonts, vector art, structure.
    public var nonImageBytes: Int { max(0, byteSize - imageObjectBytes) }

    public var imageByteFraction: Double {
        guard byteSize > 0 else { return 0 }
        return Double(imageObjectBytes) / Double(byteSize)
    }

    public var duplicateFraction: Double {
        guard byteSize > 0 else { return 0 }
        return Double(duplicateImageBytes) / Double(byteSize)
    }

    /// Image objects the file contains that CoreGraphics never showed us.
    /// Anything above zero means a rebuild would silently drop content.
    public var unresolvedImageObjects: Int {
        max(0, rawImageObjectCount - resolvedImageObjectCount)
    }

    /// True when CoreGraphics is demonstrably blind to part of this file.
    public var hasUnresolvedObjects: Bool { unresolvedImageObjects > 0 }

    public var pageClassMix: [PageClass: Int] {
        pages.reduce(into: [:]) { $0[$1.pageClass, default: 0] += 1 }
    }

    /// Below this share of the file, squeezing images cannot meaningfully help
    /// and the honest answer is "this one's already small".
    public static let worthwhileImageFraction = 0.20

    public var isWorthCompressing: Bool {
        imageByteFraction >= Self.worthwhileImageFraction
    }

    /// Above this share of the file stored more than once, de-duplication alone
    /// is worth offering as its own choice.
    ///
    /// Starting point, to be tuned against more files. On the RL deck 73% of the
    /// file is duplicated images, and removing them is 75% smaller with every
    /// pixel intact — a better outcome than any recoding profile can offer. On
    /// the RSA deck the figure is 20%, where lossless reaches only 31% and the
    /// offer would be a worse deal dressed up as a better one.
    public static let worthwhileDuplicateFraction = 0.25

    /// True when storing repeated content once is a real win on its own.
    public var isWorthDeduplicating: Bool {
        duplicateFraction >= Self.worthwhileDuplicateFraction
    }

    /// One entry per distinct image *content*, keeping the usage that draws it
    /// largest — an image reused on 28 slides must be sized for its most
    /// demanding appearance, not its smallest.
    public var uniqueImages: [ImageIdentity: ImageUsage] {
        var out: [ImageIdentity: ImageUsage] = [:]
        for image in images {
            if let existing = out[image.identity] {
                let existingArea = existing.drawnWidthPoints * existing.drawnHeightPoints
                let newArea = image.drawnWidthPoints * image.drawnHeightPoints
                if newArea > existingArea { out[image.identity] = image }
            } else {
                out[image.identity] = image
            }
        }
        return out
    }

    /// Distinct images we will refuse, with the reason, for the report.
    public var declines: [(usage: ImageUsage, reason: DeclineReason)] {
        uniqueImages.values.compactMap { usage in
            usage.declineReason.map { (usage, $0) }
        }
    }

    public var declinedBytes: Int {
        declines.reduce(0) { $0 + $1.usage.totalByteLength }
    }

    /// Distinct image content we are willing to re-encode.
    public var addressableBytes: Int {
        uniqueImages.values
            .filter(\.isRecodable)
            .reduce(0) { $0 + $1.totalByteLength }
    }

    public var addressableFraction: Double {
        guard byteSize > 0 else { return 0 }
        return Double(addressableBytes) / Double(byteSize)
    }
}
