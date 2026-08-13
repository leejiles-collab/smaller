import Foundation

/// Why we handed back the original file untouched.
public enum UnchangedReason: Sendable, Hashable {
    /// Images are less than 20% of the file. There is nothing to win.
    case alreadySmall
    /// We produced output but it was >= 98% of the input. Not worth shipping.
    case alreadyOptimized
    /// Output failed the reopen/page-count/render/text checks and was discarded.
    case failedIntegrity(IntegrityFailure)
    /// Password-protected. We do not crack or strip encryption.
    case encrypted
    /// Malformed, unreadable, or a PDF feature we refuse to guess at.
    case unsupported(String)

    public var userMessage: String {
        switch self {
        case .alreadySmall: "This one's already small."
        case .alreadyOptimized: "This one's already small."
        case .failedIntegrity: "We couldn't compress this one safely."
        case .encrypted: "This PDF is password-protected."
        case .unsupported: "We couldn't read this PDF."
        }
    }
}

public enum IntegrityFailure: Sendable, Hashable {
    case cannotReopen
    case pageCountMismatch(expected: Int, got: Int)
    case blankPage(index: Int)
    case textDisappeared
    /// A page no longer looks like the page we were given. This is what catches
    /// content that vanished rather than content that was merely compressed —
    /// a damaged cross-reference table can leave CoreGraphics unable to resolve
    /// objects it never tells us about.
    case pageContentDiverged(index: Int, difference: Double)
}

/// Something the user or the report should know about, that is not a failure.
public enum CompressionWarning: Sendable, Hashable {
    /// The document has AcroForm fields. They are copied through untouched, but
    /// we say so rather than silently shipping a form we did not verify.
    case formFieldsPresent
    /// Images we declined to re-encode (alpha, 1-bit, CCITT/JBIG2, exotic
    /// colorspace). They are copied through byte-identical.
    case imagesSkipped(count: Int, bytes: Int)
    /// A scan-like page was rasterized rather than having its images swapped.
    case pagesRasterized(count: Int)
    /// A page could not be rebuilt image-by-image and fell back to rasterizing.
    case pageFellBackToRaster(page: Int, reason: String)
    /// The target-size solver stopped at the readability floor.
    case hitReadabilityFloor
}

/// Where the bytes went, split by mechanism.
///
/// Worth keeping separate: de-duplication is free and lossless, re-encoding
/// costs quality. If a file compresses well purely because it was storing the
/// same banner twenty-eight times, that is a very different fact about the file
/// than "we threw away half its pixels", and it changes what we do next.
public struct SavingsBreakdown: Sendable {
    /// Recovered by storing repeated content once. No quality cost at all.
    public let dedupBytes: Int
    /// Recovered by re-encoding images. This is the part that costs quality.
    public let recodeBytes: Int
    public let imagesRecoded: Int
    public let masksRecoded: Int
    public let imagePlacementsDeduplicated: Int
    public let streamsDeduplicated: Int
    public let imagesDeclined: Int
    public let declinedBytes: Int
    /// Distinct images refused, counted by reason.
    public let declinesByReason: [DeclineReason: Int]
    public let declinedBytesByReason: [DeclineReason: Int]

    public static let none = SavingsBreakdown(
        dedupBytes: 0, recodeBytes: 0, imagesRecoded: 0, masksRecoded: 0,
        imagePlacementsDeduplicated: 0, streamsDeduplicated: 0,
        imagesDeclined: 0, declinedBytes: 0,
        declinesByReason: [:], declinedBytesByReason: [:]
    )
}

/// A file we actually produced.
public struct CompressedResult: Sendable {
    public let url: URL
    public let originalBytes: Int
    public let finalBytes: Int
    public let profile: CompressionProfile
    public let pageCount: Int
    /// Passes the target-size solver used. Always 1 for a fixed profile.
    public let passes: Int
    public let elapsed: TimeInterval
    public let warnings: [CompressionWarning]
    public let savings: SavingsBreakdown
    /// Lowest page correlation observed against the original, 0...1. Reported so
    /// the divergence threshold is set from data rather than taste.
    public let pageSimilarity: Double

    public var reductionFraction: Double {
        guard originalBytes > 0 else { return 0 }
        return 1.0 - (Double(finalBytes) / Double(originalBytes))
    }

    /// "88% smaller", rounded the way the pill on the Done screen shows it.
    public var reductionPercent: Int { Int((reductionFraction * 100).rounded()) }

    public init(
        url: URL,
        originalBytes: Int,
        finalBytes: Int,
        profile: CompressionProfile,
        pageCount: Int,
        passes: Int,
        elapsed: TimeInterval,
        warnings: [CompressionWarning],
        savings: SavingsBreakdown = .none,
        pageSimilarity: Double = 1
    ) {
        self.url = url
        self.originalBytes = originalBytes
        self.finalBytes = finalBytes
        self.profile = profile
        self.pageCount = pageCount
        self.passes = passes
        self.elapsed = elapsed
        self.warnings = warnings
        self.savings = savings
        self.pageSimilarity = pageSimilarity
    }
}

/// The single return type for every compression call.
public enum CompressionOutcome: Sendable {
    /// We made it smaller and it passed every gate.
    case compressed(CompressedResult)
    /// Target-size run that could not reach the target without going below the
    /// readability floor. The file is still real and still offered.
    case bestEffort(CompressedResult, target: Int)
    /// We handed back the original.
    case unchanged(reason: UnchangedReason)

    /// The file to hand the user, if there is a new one.
    public var producedURL: URL? {
        switch self {
        case .compressed(let r), .bestEffort(let r, _): r.url
        case .unchanged: nil
        }
    }

    public var result: CompressedResult? {
        switch self {
        case .compressed(let r), .bestEffort(let r, _): r
        case .unchanged: nil
        }
    }

    /// Free-tier accounting: only a real win burns a credit.
    public var burnsCredit: Bool {
        switch self {
        case .compressed, .bestEffort: true
        case .unchanged: false
        }
    }
}
