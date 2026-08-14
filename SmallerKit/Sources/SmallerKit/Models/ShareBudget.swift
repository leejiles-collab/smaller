import Foundation

/// What the share extension is allowed to take on.
///
/// ## The measurement behind these numbers
///
/// A share extension gets roughly 120 MB before the system kills it, and the
/// engine's peak on the RSA deck — 27.2 MB, ten pages, several 3999x2250 images
/// — measures about 137 MB in a release build on macOS.
///
/// That peak resists the obvious fixes, and two were tried and measured before
/// these limits were written:
///
/// - Scoping the decompressed source so it dies before the JPEG encode:
///   **worse**, 139 MB to 157 MB.
/// - Streaming the deflate instead of one big scratch buffer: **much worse**,
///   133 MB to 305 MB, because growing a `Data` in chunks thrashes the
///   allocator far more than one clean allocation does.
///
/// A lossless run, which re-encodes nothing at all, still peaks at 133 MB. So
/// the cost is not image resolution and not the encoder: it is the rebuild
/// reading and rewriting every stream in the file, and the allocator holding
/// freed pages afterwards. `CGPDFStreamCopyData` hands back whole buffers, so a
/// Flate image cannot be tiled or streamed — its decompressed size is a floor.
///
/// The macOS figure is also a pessimistic proxy. iOS excludes pages the
/// allocator has madvised as reusable from the footprint jetsam enforces, and
/// most of what is measured here is exactly that. The real number needs a
/// device.
///
/// So rather than guess, the extension checks up front whether a file is one it
/// should attempt, and hands anything bigger to the app — which has a normal
/// app's memory budget and no such ceiling.
public enum ShareBudget {

    /// TUNING DIAL. Lower these two if the extension is ever killed on a real
    /// device; raise them if it comfortably handles more. Nothing else needs to
    /// change — both the extension's guard and its user-facing message read
    /// from here.
    public static let maxInputBytes = 30_000_000

    /// Largest single image, in pixels, the extension will decode in-process.
    /// The RSA deck's biggest is 3999x2250, just under 9 megapixels.
    public static let maxImagePixels = 12_000_000

    /// Whether the extension should do this one itself.
    ///
    /// A false answer is not a failure: it means "the app should do this", and
    /// the extension offers exactly that rather than starting work it might not
    /// finish.
    public static func canRunInExtension(_ inventory: PDFInventory) -> Bool {
        guard inventory.byteSize <= maxInputBytes else { return false }
        let largest = inventory.uniqueImages.values
            .map { $0.pixelWidth * $0.pixelHeight }
            .max() ?? 0
        return largest <= maxImagePixels
    }
}
