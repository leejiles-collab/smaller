import Foundation

/// A scratch directory that cleans up after itself.
///
/// Everything the engine writes lands here. The original file is never opened
/// for writing, never moved, and never touched in any way.
public final class TempWorkspace: @unchecked Sendable {

    public let directory: URL
    private let lock = NSLock()
    private var cleaned = false

    public init(name: String = "smaller") throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.directory = base
    }

    /// A fresh URL inside the workspace. Nothing is created on disk yet.
    public func url(named name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: false)
    }

    public func url(forPass pass: Int, extension ext: String = "pdf") -> URL {
        url(named: "pass-\(pass).\(ext)")
    }

    /// Removes everything. Safe to call more than once, and called on dealloc so
    /// a cancelled task cannot leak a 40 MB intermediate.
    public func cleanUp() {
        lock.lock()
        defer { lock.unlock() }
        guard !cleaned else { return }
        cleaned = true
        try? FileManager.default.removeItem(at: directory)
    }

    /// Deletes every file in the workspace except one — used to keep the
    /// winning pass and drop the losers.
    public func discardAll(except keep: URL?) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where url.standardizedFileURL != keep?.standardizedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    deinit {
        cleanUp()
    }
}

enum FileSize {
    static func bytes(at url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}

/// Human-readable byte counts, matching what the UI will show.
public enum ByteFormat {
    public static func string(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        let kb = Double(bytes) / 1_000
        return String(format: "%.0f KB", kb)
    }
}
