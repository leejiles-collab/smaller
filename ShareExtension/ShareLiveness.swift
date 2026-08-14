import Foundation
import SmallerKit

/// A note the extension leaves on disk while it is running.
///
/// The extension's worst failure is the system killing the process: there is no
/// code left to run and nothing left to draw with, so the failure is invisible —
/// the user sees a blank sheet and nothing ever explains it.
///
/// So each run writes down what it was about to attempt and erases it on the way
/// out. A note still sitting there at the next launch means the last run never
/// got to leave, and the next sheet can say so.
enum ShareLiveness {

    enum Stage: String {
        /// Up and drawing, but not yet holding a file.
        case starting
        /// Copying the shared file in and parsing it.
        case reading
        /// Rebuilding the document.
        case compressing

        /// What to tell the user on the run *after* one that died here.
        var report: String {
            switch self {
            case .starting:
                "Smaller closed unexpectedly last time it was opened here."
            case .reading:
                "Smaller ran out of room reading the last file. Something that big is better opened in the app."
            case .compressing:
                "Smaller ran out of room compressing the last file. The app has more, and can finish it."
            }
        }
    }

    private static var noteURL: URL? {
        SharedContainer.url?.appendingPathComponent("share-liveness", isDirectory: false)
    }

    /// Records what the extension is about to attempt.
    static func mark(_ stage: Stage) {
        guard let noteURL else { return }
        try? Data(stage.rawValue.utf8).write(to: noteURL, options: .atomic)
    }

    /// Reads, and clears, a note the previous run did not live long enough to
    /// erase. Nil in the ordinary case where it exited cleanly.
    ///
    /// Call this before `mark` — the first thing a run does would otherwise
    /// overwrite the evidence.
    static func takeUnfinished() -> Stage? {
        guard let noteURL, let data = try? Data(contentsOf: noteURL) else { return nil }
        clear()
        return Stage(rawValue: String(decoding: data, as: UTF8.self))
    }

    /// Erased on every ordinary way out, so what survives is only ever a kill.
    static func clear() {
        guard let noteURL else { return }
        try? FileManager.default.removeItem(at: noteURL)
    }
}
