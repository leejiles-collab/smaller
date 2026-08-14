import Foundation

/// Somewhere of our own to keep the file being worked on.
///
/// `fileImporter` hands back a security-scoped URL: access has to be opened and
/// closed in balance, it can be revoked, and on iOS the file may live in another
/// process's container. The engine reads its input several times — once to
/// parse, once per pass, once more to verify the output against it — so rather
/// than hold a scoped resource open across all of that, the file is copied once
/// and the original is never touched again.
final class ImportWorkspace {

    enum ImportError: Error {
        case cannotAccess
        case cannotCopy
    }

    private let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("smaller-inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Copies the picked file in and returns what we know about it.
    func take(_ pickedURL: URL) throws -> ImportedFile {
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }

        clear()
        let name = pickedURL.lastPathComponent
        let destination = directory.appendingPathComponent(name.isEmpty ? "input.pdf" : name)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: pickedURL, to: destination)
        } catch {
            throw ImportError.cannotCopy
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
        return ImportedFile(url: destination, displayName: name, byteSize: size)
    }

    /// Puts the finished file under the name the user chose, ready to hand to
    /// the share sheet or the file exporter.
    func named(_ name: String, copying source: URL) -> URL {
        let destination = directory.appendingPathComponent(sanitized(name))
        guard destination != source else { return source }

        // Already there from a previous pass over this screen. Re-copying a
        // finished file every time the view rebuilds would be pure waste.
        let sizeOf: (URL) -> Int? = {
            try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int
        }
        if let existing = sizeOf(destination), let original = sizeOf(source), existing == original {
            return destination
        }

        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            // Sharing the engine's own filename is a worse outcome than not
            // sharing at all, but only just — hand back what we have.
            return source
        }
    }

    /// A filename, not a path. Anything that could climb out of the directory
    /// is replaced rather than rejected.
    private func sanitized(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "smaller.pdf" : cleaned
    }

    /// Drops every file we imported or renamed. Called when the user goes home,
    /// so a 28 MB deck does not sit in the container until the OS feels like
    /// clearing it.
    func clear() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
