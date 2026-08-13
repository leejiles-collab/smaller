import Foundation

/// Predicts how big a document will be after compression, from the actual
/// inventory rather than a flat percentage guess.
///
/// The prediction is **not** shown in the app. It exists so the target-size
/// solver can pick a sensible first pass instead of starting from a coin flip,
/// and so the CLI report can tell us how wrong it is. If it lands within ±15%
/// across the fixture set we can revisit showing it.
enum SizeEstimator {

    /// Tunables. Every number here is empirical — adjust from the CLI report's
    /// prediction-error column, not from taste.
    ///
    /// The curve is fitted against ImageIO's actual JPEG output rather than
    /// guessed: measured 0.99 / 1.36 / 1.72 bits per pixel at quality
    /// 0.35 / 0.50 / 0.65, which is close to linear over the range we use.
    enum Constants {
        /// JPEG bits per pixel as a function of quality, for photographic RGB.
        static func bitsPerPixel(quality: Double) -> Double {
            0.14 + 2.4 * quality
        }
        /// Scans are flatter than photographs, but scanner noise claws some of
        /// that back. Tune this from real fixtures.
        static let scanContentFactor = 0.65
        static let mixedContentFactor = 1.0
        /// One channel instead of three, but chroma was already subsampled, so
        /// the saving is nothing like a third.
        static let grayscaleFactor = 0.70
        /// Per-object overhead we add back: object headers, xref rows, the
        /// re-deflated content streams.
        static let structuralOverheadPerObject = 60
    }

    /// Projected byte size for one image re-encoded at `profile`.
    static func projectedBytes(
        for image: ImageUsage,
        profile: CompressionProfile,
        onScanLikePage: Bool
    ) -> Int {
        guard image.isRecodable else { return image.rawByteLength }

        let scale = downsampleScale(for: image, targetDPI: profile.targetDPI)
        let pixels = Double(image.pixelWidth) * Double(image.pixelHeight) * scale * scale

        let grayscale = profile.allowsGrayscaleForScans && onScanLikePage
        var bpp = Constants.bitsPerPixel(quality: profile.jpegQuality)
        bpp *= onScanLikePage ? Constants.scanContentFactor : Constants.mixedContentFactor
        if grayscale { bpp *= Constants.grayscaleFactor }

        let projected = Int(pixels * bpp / 8.0)
        // We only ever keep the re-encode when it actually wins, so the original
        // length is a hard ceiling on what this image can cost us.
        return min(projected, image.rawByteLength)
    }

    /// Linear scale factor to bring an image down to the profile's target DPI.
    /// Never upscales.
    static func downsampleScale(for image: ImageUsage, targetDPI: Double) -> Double {
        let dpi = image.effectiveDPI
        guard dpi > 1 else { return 1 }
        return min(1.0, targetDPI / dpi)
    }

    /// A scan-like page is replaced wholesale by one JPEG of the whole page, so
    /// its cost is set by the page's dimensions and the profile's DPI — not by
    /// what its original images happened to contain.
    static func rasterizedPageBytes(_ page: PageSummary, profile: CompressionProfile) -> Int {
        let pixels = (page.widthPoints / 72.0 * profile.targetDPI)
            * (page.heightPoints / 72.0 * profile.targetDPI)
        var bpp = Constants.bitsPerPixel(quality: profile.jpegQuality) * Constants.scanContentFactor
        if profile.allowsGrayscaleForScans { bpp *= Constants.grayscaleFactor }
        return Int(pixels * bpp / 8.0)
    }

    /// Whole-document prediction.
    static func estimate(
        inventory: PDFInventory,
        profile: CompressionProfile
    ) -> Int {
        let scanLikePages = Set(inventory.pages.filter { $0.pageClass == .scanLike }.map(\.index))

        var total = 0
        for page in inventory.pages where scanLikePages.contains(page.index) {
            total += rasterizedPageBytes(page, profile: profile)
        }

        for (_, image) in inventory.uniqueImages {
            // Images on scan-like pages are subsumed by the page raster above.
            guard !scanLikePages.contains(image.pageIndex) else { continue }
            total += projectedBytes(for: image, profile: profile, onScanLikePage: false)
        }

        let overhead = inventory.uniqueImages.count * Constants.structuralOverheadPerObject
        return inventory.nonImageBytes + total + overhead
    }

    static func estimates(inventory: PDFInventory) -> [CompressionProfile: Int] {
        var out: [CompressionProfile: Int] = [:]
        for profile in CompressionProfile.presets {
            out[profile] = estimate(inventory: inventory, profile: profile)
        }
        return out
    }

    /// Inverts the model to guess the DPI/quality pair that lands on `target`.
    /// Only ever a starting point — the solver measures and corrects from here.
    static func startingProfile(inventory: PDFInventory, targetBytes: Int) -> CompressionProfile {
        let budget = targetBytes - inventory.nonImageBytes
        guard budget > 0 else {
            return .custom(dpi: CompressionProfile.Floor.dpi, quality: CompressionProfile.Floor.quality, grayscale: true)
        }

        // Walk the presets first; if one already fits, start from it.
        for profile in CompressionProfile.presets where estimate(inventory: inventory, profile: profile) <= targetBytes {
            return profile
        }

        // Otherwise interpolate below `.tiny` down to the floor.
        var best = CompressionProfile.custom(dpi: CompressionProfile.Floor.dpi,
                                             quality: CompressionProfile.Floor.quality,
                                             grayscale: true)
        var dpi = CompressionProfile.tiny.targetDPI
        var quality = CompressionProfile.tiny.jpegQuality
        for _ in 0..<8 {
            let candidate = CompressionProfile.custom(dpi: dpi, quality: quality, grayscale: true)
            if estimate(inventory: inventory, profile: candidate) <= targetBytes {
                best = candidate
                break
            }
            dpi = max(CompressionProfile.Floor.dpi, dpi * 0.85)
            quality = max(CompressionProfile.Floor.quality, quality * 0.9)
            if dpi <= CompressionProfile.Floor.dpi && quality <= CompressionProfile.Floor.quality { break }
        }
        return best
    }
}

extension PDFInventory {
    /// One entry per distinct image, keeping the usage that draws it largest —
    /// an image reused on 40 pages must be sized for its most demanding
    /// appearance, not its smallest.
    public var uniqueImages: [ImageKey: ImageUsage] {
        var out: [ImageKey: ImageUsage] = [:]
        for image in images {
            if let existing = out[image.key] {
                let existingArea = existing.drawnWidthPoints * existing.drawnHeightPoints
                let newArea = image.drawnWidthPoints * image.drawnHeightPoints
                if newArea > existingArea { out[image.key] = image }
            } else {
                out[image.key] = image
            }
        }
        return out
    }
}
