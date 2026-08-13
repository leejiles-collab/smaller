import Foundation

/// The one and only place the bundle identifier prefix is written down.
///
/// >  CHANGE ME: replace `PLACEHOLDER` with your Apple Developer team's
/// >  reverse-DNS prefix (for example `com.leejiles`). Then re-run
/// >  `Tools/generate-project.sh` so the Xcode project picks it up.
public enum BundleConfig {

    /// Reverse-DNS prefix shared by every target. Nothing else in the codebase
    /// hard-codes a bundle identifier.
    public static let prefix = "com.PLACEHOLDER"

    public static var appBundleID: String { "\(prefix).smaller" }
    public static var shareExtensionBundleID: String { "\(prefix).smaller.share" }

    /// App Group shared by the app and the share extension. Compressed output
    /// and the free-tier counter live here.
    public static var appGroupID: String { "group.\(prefix).smaller" }

    /// True when the placeholder has not been replaced yet.
    public static var isPlaceholder: Bool { prefix.contains("PLACEHOLDER") }
}
