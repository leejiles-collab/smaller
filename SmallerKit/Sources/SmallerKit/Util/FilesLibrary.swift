import Foundation

/// The Smaller folder — the copy of the file the user can still find tomorrow.
///
/// ## Why there are two directories here
///
/// `UIFileSharingEnabled` publishes exactly one directory to the Files app: the
/// *app's* Documents. An app extension has its own container and cannot write
/// there — the App Group is the only ground the two share. So the app writes
/// straight into the visible folder, the share extension stages into the group,
/// and the app adopts anything staged the next time it runs.
///
/// Everything that leaves either path goes through here, so the naming and the
/// collision rule are the same wherever the file came from.
public enum FilesLibrary {

    /// "Board Deck.pdf" -> "Board Deck-smaller.pdf"
    public static func outputName(for originalName: String) -> String {
        let base = (originalName as NSString).deletingPathExtension
        return "\(base)-smaller.pdf"
    }

    /// What to call this folder when telling the user where their file went.
    public static let userFacingLocation = "Files → Smaller"

    // MARK: - The visible folder

    /// The app's Documents directory, which the Files app shows as
    /// *On My iPhone → Smaller*.
    ///
    /// Only meaningful inside the app. An extension asking for this gets its
    /// own container's Documents, which nothing can see — hence `stage`.
    public static var visibleDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// Copies a finished file into the visible folder and returns where it
    /// landed, which is not always the name that was asked for.
    @discardableResult
    public static func save(_ file: URL, as preferredName: String) throws -> URL {
        guard let directory = visibleDirectory else {
            throw CocoaError(.fileNoSuchFile)
        }
        let destination = uniqueURL(in: directory, preferredName: preferredName)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    // MARK: - The extension's staging area

    /// Where the share extension leaves finished work for the app to file.
    ///
    /// Deliberately not swept on a timer the way `handoff` and `outbox` are:
    /// this is the user's copy, and it waits as long as it takes for them to
    /// open the app.
    public static func stagingDirectory() -> URL? {
        guard let base = SharedContainer.url else { return nil }
        let directory = base.appendingPathComponent("saved", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The extension's half of `save`. Same naming, same collision rule, a
    /// directory the extension is actually allowed to write to.
    @discardableResult
    public static func stage(_ file: URL, as preferredName: String) throws -> URL {
        guard let directory = stagingDirectory() else {
            throw CocoaError(.fileNoSuchFile)
        }
        let destination = uniqueURL(in: directory, preferredName: preferredName)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    /// Moves everything the extension staged into the visible folder. Called on
    /// app launch, which is the first moment anything is able to.
    ///
    /// Returns what it filed, so the app can say so.
    @discardableResult
    public static func adoptStaged() -> [URL] {
        guard let staging = stagingDirectory(), visibleDirectory != nil else { return [] }
        let staged = (try? FileManager.default.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: nil
        )) ?? []

        var adopted: [URL] = []
        for file in staged.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let landed = try? save(file, as: file.lastPathComponent) else { continue }
            try? FileManager.default.removeItem(at: file)
            adopted.append(landed)
        }
        return adopted
    }

    // MARK: - Naming

    /// `report-smaller.pdf`, then `report-smaller-2.pdf`, `-3`, and so on.
    ///
    /// Never overwrites. Someone compressing the same document twice at two
    /// different settings wants both, and the one they already had is not ours
    /// to throw away.
    public static func uniqueURL(in directory: URL, preferredName: String) -> URL {
        let name = preferredName as NSString
        let base = name.deletingPathExtension
        let ext = name.pathExtension.isEmpty ? "pdf" : name.pathExtension

        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
