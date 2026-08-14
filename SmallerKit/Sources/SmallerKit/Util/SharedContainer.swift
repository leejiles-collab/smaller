import Foundation

/// The App Group container, which is the only place the app and the share
/// extension can both reach.
///
/// Two things live here: files handed from the extension to the app when a
/// document is too big for the extension to take on, and the free-credit count.
public enum SharedContainer {

    public static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BundleConfig.appGroupID)
    }

    /// Where the extension leaves a file for the app to pick up.
    public static func handoffDirectory() -> URL? {
        guard let base = url else { return nil }
        let directory = base.appendingPathComponent("handoff", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Where the extension writes finished output for the host app to read.
    ///
    /// The host — Mail, Files, Messages — reads the returned file *after* the
    /// extension has gone, so it cannot live in the extension's own temporary
    /// directory.
    public static func outputDirectory() -> URL? {
        guard let base = url else { return nil }
        let directory = base.appendingPathComponent("outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Drops anything left over from previous runs. Old output has already been
    /// handed to the host, and old handoffs have already been opened.
    public static func sweep(olderThan age: TimeInterval = 3600) {
        let now = Date()
        for directory in [handoffDirectory(), outputDirectory()].compactMap({ $0 }) {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            for file in contents {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if now.timeIntervalSince(modified) > age {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }
}
