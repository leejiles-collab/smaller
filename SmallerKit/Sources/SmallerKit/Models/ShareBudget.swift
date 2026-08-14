import Foundation
#if os(iOS)
import os
#endif

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

    /// Memory the process may still allocate before the system kills it.
    ///
    /// `os_proc_available_memory` is the only honest answer to "will this fit":
    /// it reports the actual remaining headroom for *this* process on *this*
    /// device, rather than a number guessed from a macOS measurement. Zero on
    /// anything that is not iOS, where the static caps below decide instead.
    public static var availableMemory: Int {
        #if os(iOS)
        return Int(os_proc_available_memory())
        #else
        return 0
        #endif
    }

    /// What a rebuild of this document is likely to need at its worst moment.
    ///
    /// Fitted to measurement rather than derived: the RSA deck, whose largest
    /// image is 27 MB decompressed, peaks around 137 MB, and the RL deck, whose
    /// largest is 6.6 MB, peaks around 92 MB. Both sit under `base + 4x`, which
    /// is deliberately the pessimistic side of the fit — being wrong in this
    /// direction costs one extra tap, and being wrong in the other costs a
    /// killed extension in the middle of someone's email.
    public static func estimatedPeakBytes(_ inventory: PDFInventory) -> Int {
        let largestDecoded = inventory.uniqueImages.values
            .map { $0.pixelWidth * $0.pixelHeight * max(1, $0.componentCount) }
            .max() ?? 0
        return baseBytes + peakMultiple * largestDecoded
    }

    /// TUNING DIALS for the estimate above. If device testing shows the
    /// extension comfortably handling files it currently hands off, lower
    /// `peakMultiple` first.
    public static let baseBytes = 60_000_000
    public static let peakMultiple = 4


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
        guard largest <= maxImagePixels else { return false }

        // Then the question the static caps can only approximate: is there
        // actually room, here, now?
        let available = availableMemory
        guard available > 0 else { return true }
        return estimatedPeakBytes(inventory) < available
    }
}
