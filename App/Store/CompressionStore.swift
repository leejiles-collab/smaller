import Foundation
import Observation
import SmallerKit

/// A PDF the user handed us, copied somewhere we control.
///
/// The picker returns a security-scoped URL whose access has to be balanced and
/// which can vanish underneath us. Everything downstream reads the file several
/// times — once to parse, once per pass — so it is copied first and the
/// original is never opened again.
struct ImportedFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let displayName: String
    let byteSize: Int

    /// "Board Deck.pdf" -> "Board Deck-smaller.pdf"
    var suggestedOutputName: String { FilesLibrary.outputName(for: displayName) }
}

/// The finished article, plus everything the Done screen needs to describe it
/// honestly.
struct Finished {
    let result: CompressedResult
    let intent: Intent
    /// False when a target-size run bottomed out above its target. Not an
    /// error: the file is real and still offered.
    let metTarget: Bool
    var exportName: String

    var pageCount: Int { result.pageCount }

    /// The one context line under the numbers. Never claims "no quality loss"
    /// for a profile that re-encodes images — the only run that may say so is
    /// the lossless one, where it happens to be true.
    var contextLine: String {
        let pages = pageCount == 1 ? "1 page" : "\(pageCount) pages"
        switch intent {
        case .profile(let profile):
            return profile.recodesImages
                ? "\(pages) · \(profile.doneScreenNote)"
                : "\(pages) · Every pixel preserved"
        case .target(let bytes):
            return metTarget
                ? "\(pages) · Under \(ByteFormat.string(bytes))"
                : "\(pages) · Smallest we could make it"
        }
    }

    /// Warnings the user actually needs. Everything else stays in the report.
    var surfacedWarnings: [SurfacedWarning] {
        result.warnings.compactMap(SurfacedWarning.init)
    }
}

/// The two warnings that change what a person would do next.
enum SurfacedWarning: Identifiable, Hashable {
    /// They are about to send a form somewhere and should know it is a form.
    case formFields
    /// The file was damaged and some of it may not have carried through.
    case possibleContentLoss(missing: Int, of: Int)

    init?(_ warning: CompressionWarning) {
        switch warning {
        case .formFieldsPresent:
            self = .formFields
        case .possibleObjectLoss(let missing, let total):
            self = .possibleContentLoss(missing: missing, of: total)
        default:
            // Skipped images, rasterized pages and the readability floor are
            // engine detail. Saying them out loud would be noise.
            return nil
        }
    }

    var id: String {
        switch self {
        case .formFields: "formFields"
        case .possibleContentLoss(let missing, let total): "loss-\(missing)-\(total)"
        }
    }

    var title: String {
        switch self {
        case .formFields: "This PDF has form fields"
        case .possibleContentLoss: "This PDF was damaged"
        }
    }

    var detail: String {
        switch self {
        case .formFields:
            "The fields were copied across untouched, but we could not verify "
            + "them. Check the form still works before sending it."
        case .possibleContentLoss(let missing, let total):
            "\(missing) of \(total) images in the file could not be read, so "
            + "some content may not have carried through. Keep the original if "
            + "anything looks missing."
        }
    }
}

@MainActor
@Observable
final class CompressionStore {

    enum Phase {
        case home
        /// Parsing. Brief, but a 28 MB deck is not instant.
        case analyzing(ImportedFile)
        case ready(ImportedFile, PDFInventory)
        case working(ImportedFile, PDFInventory, Progress)
        case finished(Finished)
        /// Honest dead ends: nothing to gain, or we could not do it.
        case nothingToGain(ImportedFile, String)
        case failed(String)
        /// Free compressions are gone. Shown only at the moment it blocks
        /// something, never as a permanent banner.
        case paywall(ImportedFile, PDFInventory)
    }

    struct Progress {
        var fraction: Double = 0
        var pass: Int = 1
        var isConverging: Bool = false
        let intent: Intent

        /// Explains the extra seconds rather than letting them look like a hang.
        var subtitle: String {
            guard isConverging, case .target(let bytes) = intent else {
                return "Making it smaller…"
            }
            return "Still working — getting it under \(ByteFormat.string(bytes))"
        }
    }

    /// What happened to the user's own copy of the finished file.
    ///
    /// Not a button and not a choice: every finished compression is written to
    /// the Files app before anything is offered, because a share sheet that
    /// hands a file to Mail and gets nothing back leaves the user with nothing
    /// at all. Sharing and exporting are extras on top of a file that already
    /// exists.
    enum SavedState {
        case pending
        case saved(URL)
        case failed(String)
    }

    private(set) var phase: Phase = .home
    private(set) var saved: SavedState = .pending

    /// Selection on the analysis screen. Deliberately one value: the size field
    /// and the intent cards are the same choice, so they cannot both be on.
    var intent: Intent = .profile(.sendIt)
    var targetMegabytes: Double = 5

    var targetBytes: Int { Int(targetMegabytes * 1_000_000) }

    private var engine: CompressionEngine?
    private var task: Task<Void, Never>?
    private let workspace = ImportWorkspace()
    private let credits = CreditStore()
    let purchases = PurchaseStore()

    /// Credits left, but only worth mentioning when they are nearly gone. A
    /// running counter on every screen would turn a utility into a meter.
    private(set) var creditsRemaining: Int = CreditStore.freeCompressions
    var shouldMentionCredits: Bool {
        creditsRemaining <= Self.creditWarningThreshold && creditsRemaining > 0
    }

    /// Say something only once the number is small enough to matter.
    static let creditWarningThreshold = 3

    private(set) var isPro = false

    // MARK: - Picking a file

    func open(pickedURL: URL) {
        cancelWork()
        do {
            let imported = try workspace.take(pickedURL)
            phase = .analyzing(imported)
            analyze(imported)
        } catch {
            phase = .failed("We couldn't open that file.")
        }
    }

    func failedToPick() {
        phase = .failed("We couldn't open that file.")
    }

    private func analyze(_ file: ImportedFile) {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let engine = try self.makeEngine()
                let inventory = try await engine.inventory(url: file.url)
                guard !Task.isCancelled else { return }

                if inventory.isLocked {
                    self.phase = .nothingToGain(file, UnchangedReason.encrypted.userMessage)
                    return
                }
                // Lossless is only offered when it is a genuinely better answer
                // than any recoding profile, so it must not be the default.
                self.intent = .profile(.sendIt)
                self.phase = .ready(file, inventory)
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed("We couldn't read that PDF.")
            }
        }
    }

    // MARK: - Compressing

    func start() {
        guard case .ready(let file, let inventory) = phase else { return }
        let intent = self.intent

        // The gate is here, at the moment work would begin, and nowhere else.
        if creditsRemaining == 0 && !isPro {
            phase = .paywall(file, inventory)
            return
        }

        phase = .working(file, inventory, Progress(intent: intent))

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let engine = try self.makeEngine()
                let events = switch intent {
                case .profile(let profile): engine.events(url: file.url, profile: profile)
                case .target(let bytes): engine.events(url: file.url, targetBytes: bytes)
                }

                for try await event in events {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .progress(let progress):
                        self.apply(progress, file: file, intent: intent)
                    case .finished(let outcome):
                        self.finish(outcome, file: file, intent: intent)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed("Something went wrong compressing that file.")
            }
        }
    }

    private func apply(_ progress: CompressionProgress, file: ImportedFile, intent: Intent) {
        guard case .working(let workingFile, let inventory, var current) = phase,
              workingFile.id == file.id else { return }
        // Never let the ring go backwards: a target-size run reports per-pass
        // fractions, and pass 2 starting over would read as the work restarting.
        current.fraction = max(current.fraction, progress.fraction)
        current.pass = progress.pass
        current.isConverging = progress.isConverging
        phase = .working(workingFile, inventory, current)
    }

    private func finish(_ outcome: CompressionOutcome, file: ImportedFile, intent: Intent) {
        // Only a file we actually produced costs a credit. A refusal, a failed
        // integrity check or a cancelled run is free.
        if outcome.burnsCredit {
            Task { [credits] in
                await credits.spend()
                await self.refreshCredits()
            }
        }
        switch outcome {
        case .compressed(let result):
            phase = .finished(Finished(
                result: result, intent: intent, metTarget: true,
                exportName: file.suggestedOutputName
            ))
        case .bestEffort(let result, _):
            phase = .finished(Finished(
                result: result, intent: intent, metTarget: false,
                exportName: file.suggestedOutputName
            ))
        case .unchanged(let reason):
            phase = .nothingToGain(file, reason.userMessage)
        }
    }

    // MARK: - Leaving

    /// Stops the running work and hands the user back their choices.
    ///
    /// The button can afford to be always live because this is all it has to
    /// do: the engine polls for cancellation between pages, and every
    /// intermediate file it wrote is dropped by its own workspace on the way
    /// out. Nothing here waits for the work to notice.
    func cancelWork() {
        task?.cancel()
        task = nil
        if case .working(let file, let inventory, _) = phase {
            phase = .ready(file, inventory)
        }
    }

    func cancelAndReturnHome() {
        task?.cancel()
        task = nil
        let engine = self.engine
        Task { await engine?.discardOutputs() }
        workspace.clear()
        phase = .home
        // The file stays in the Files app. What is dropped is this run's memory
        // of having put it there.
        saved = .pending
    }

    func compressAnother() {
        cancelAndReturnHome()
    }

    /// Renames the produced file for sharing and exporting. The engine's own
    /// filenames are internal; what leaves the app is what the user typed.
    func exportURL(for finished: Finished) -> URL {
        workspace.named(finished.exportName, copying: finished.result.url)
    }

    func rename(_ name: String) {
        guard case .finished(var finished) = phase else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        finished.exportName = trimmed.hasSuffix(".pdf") ? trimmed : trimmed + ".pdf"
        phase = .finished(finished)
        renameSavedCopy(to: finished.exportName)
    }

    // MARK: - Filing it where the user can find it

    /// Writes the finished file to *On My iPhone → Smaller*. Called as the Done
    /// screen appears, before the user is offered anything to do with it.
    func fileIntoLibrary(_ finished: Finished) {
        guard case .pending = saved else { return }
        do {
            let landed = try FilesLibrary.save(
                finished.result.url, as: finished.exportName
            )
            saved = .saved(landed)
        } catch {
            saved = .failed((error as NSError).localizedDescription)
        }
    }

    /// Keeps the filed copy's name in step with a rename on the Done screen,
    /// rather than leaving a stale name in the folder and a fresh one on screen.
    private func renameSavedCopy(to name: String) {
        guard case .saved(let current) = saved else { return }
        let destination = FilesLibrary.uniqueURL(
            in: current.deletingLastPathComponent(), preferredName: name
        )
        do {
            try FileManager.default.moveItem(at: current, to: destination)
            saved = .saved(destination)
        } catch {
            saved = .failed((error as NSError).localizedDescription)
        }
    }

    /// Takes in anything the share extension saved while the app was not
    /// running. The extension cannot write to the Files folder itself — separate
    /// sandbox — so this is the moment its work becomes visible.
    func adoptExtensionOutput() {
        FilesLibrary.adoptStaged()
    }

    /// Called at launch and after anything that could change either number.
    func refreshEntitlements() async {
        await purchases.start()
        isPro = await purchases.isPro
        await refreshCredits()
    }

    private func refreshCredits() async {
        creditsRemaining = await credits.remaining
    }

    func purchased() {
        isPro = true
        if case .paywall(let file, let inventory) = phase {
            phase = .ready(file, inventory)
        }
    }

    func dismissPaywall() {
        if case .paywall(let file, let inventory) = phase {
            phase = .ready(file, inventory)
        }
    }

    /// Opens a file the share extension handed over because it was too big to
    /// process inside the extension's memory budget.
    func openHandoff(named name: String) {
        guard let directory = SharedContainer.handoffDirectory() else { return }
        let source = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        open(pickedURL: source)
        // It has been copied into our own workspace by now.
        try? FileManager.default.removeItem(at: source)
    }

    private func makeEngine() throws -> CompressionEngine {
        if let engine { return engine }
        let made = try CompressionEngine()
        engine = made
        return made
    }
}
