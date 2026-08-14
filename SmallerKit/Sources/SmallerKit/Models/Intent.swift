import Foundation

/// What the user asked for. One choice, never two: picking a profile clears the
/// size target and picking a size target clears the profile.
///
/// Shared by the app and the share extension, which offer the same choice in
/// two different shapes.
public enum Intent: Hashable, Sendable {
    case profile(CompressionProfile)
    case target(bytes: Int)

    public var isTarget: Bool {
        if case .target = self { return true }
        return false
    }
}
