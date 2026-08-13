import Foundation

/// A compression setting. The three shipping profiles are named constants at the
/// bottom of this file — tune the numbers there and nowhere else.
///
/// The type is also used for the ad-hoc settings the target-size solver invents
/// between passes, which is why it is a struct and not an enum.
public struct CompressionProfile: Hashable, Sendable, Identifiable {

    /// Stable identity. The three presets use `sendIt` / `small` / `tiny`;
    /// solver-generated profiles use `custom`.
    public let id: String

    /// What the user sees on the intent card.
    public let userLabel: String

    /// One-line description under the label.
    public let userDescription: String

    /// Images are downsampled so they land at (at most) this many dots per inch
    /// of the area they actually cover on the page.
    public let targetDPI: Double

    /// `kCGImageDestinationLossyCompressionQuality` for the re-encoded JPEGs.
    public let jpegQuality: Double

    /// Allow dropping scan-like pages to grayscale. Only `.tiny` does this.
    public let allowsGrayscaleForScans: Bool

    public init(
        id: String,
        userLabel: String,
        userDescription: String,
        targetDPI: Double,
        jpegQuality: Double,
        allowsGrayscaleForScans: Bool
    ) {
        self.id = id
        self.userLabel = userLabel
        self.userDescription = userDescription
        self.targetDPI = targetDPI
        self.jpegQuality = jpegQuality
        self.allowsGrayscaleForScans = allowsGrayscaleForScans
    }

    // MARK: - Readability floor

    /// Below these values output stops being worth handing to a human, so the
    /// target-size solver refuses to go further no matter what the target says.
    public enum Floor {
        public static let dpi: Double = 72
        public static let quality: Double = 0.30
    }

    /// Above these values we are not compressing, just re-encoding.
    public enum Ceiling {
        public static let dpi: Double = 300
        public static let quality: Double = 0.85
    }

    /// Clamps an arbitrary DPI/quality pair into the shippable range.
    public static func custom(dpi: Double, quality: Double, grayscale: Bool = false) -> CompressionProfile {
        CompressionProfile(
            id: "custom",
            userLabel: "Custom",
            userDescription: "Target size",
            targetDPI: min(max(dpi, Floor.dpi), Ceiling.dpi),
            jpegQuality: min(max(quality, Floor.quality), Ceiling.quality),
            allowsGrayscaleForScans: grayscale
        )
    }

    /// True when this profile is already sitting on the readability floor.
    public var isAtFloor: Bool {
        targetDPI <= Floor.dpi + 0.01 && jpegQuality <= Floor.quality + 0.001
    }

    // MARK: - The three shipping profiles

    public static let sendIt = CompressionProfile(
        id: "sendIt",
        userLabel: "Send it",
        userDescription: "Best balance",
        targetDPI: 150,
        jpegQuality: 0.65,
        allowsGrayscaleForScans: false
    )

    public static let small = CompressionProfile(
        id: "small",
        userLabel: "Make it small",
        userDescription: "Good for uploading",
        targetDPI: 110,
        jpegQuality: 0.50,
        allowsGrayscaleForScans: false
    )

    public static let tiny = CompressionProfile(
        id: "tiny",
        userLabel: "Make it tiny",
        userDescription: "Maximum compression",
        targetDPI: 72,
        jpegQuality: 0.35,
        allowsGrayscaleForScans: true
    )

    /// Presentation order, and the order the CLI report walks.
    public static let presets: [CompressionProfile] = [.sendIt, .small, .tiny]

    /// Restated on the Done screen: "42 pages · Optimized for email".
    public var doneScreenNote: String {
        switch id {
        case "sendIt": "Optimized for email"
        case "small": "Optimized for uploading"
        case "tiny": "Maximum compression"
        default: "Custom size"
        }
    }
}
