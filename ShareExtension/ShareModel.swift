import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers
import SmallerKit

/// The share sheet's state machine.
///
/// Smaller than the app's: there is one file, it arrived rather than being
/// chosen, and the only way out is back to whatever app the user was already in.
@MainActor
@Observable
final class ShareModel {

    enum Phase {
        case loading
        case ready(ImportedItem, PDFInventory)
        case working(Double)
        case finished(Delivered)
        /// Too big for the extension's memory budget. Not a failure — the app
        /// can do it, and this offers exactly that.
        case handOff(ImportedItem, String)
        case paywall(ImportedItem, PDFInventory)
        case failed(Failure)
    }

    /// Why we stopped, in two registers: one line the user can act on, and the
    /// underlying reason underneath it.
    ///
    /// The detail is shown, not swallowed. A share sheet that says only "went
    /// wrong" is barely better than the blank one it replaced, and this is the
    /// only place the user will ever see why.
    struct Failure {
        let message: String
        let detail: String?

        init(_ message: String, underlying: Error? = nil) {
            self.message = message
            self.detail = underlying.map { ($0 as NSError).localizedDescription }
        }
    }

    struct ImportedItem {
        let url: URL
        let displayName: String
        let byteSize: Int
    }

    /// A finished compression and the two places the file now is.
    struct Delivered {
        let result: CompressedResult
        /// The copy the host app gets if the user taps "Attach it".
        let attachment: URL
        /// The user's own copy, which exists whether or not they tap anything.
        let saved: SavedState
    }

    /// What happened to the copy we keep for the user.
    ///
    /// The bug this exists to stop: the user shares a received Mail attachment,
    /// taps "Attach it", and Mail — with no draft to attach it to — accepts the
    /// file and drops it. The user is left with nothing to show for the work.
    /// So the file is written somewhere durable *first*, and every button after
    /// that is optional.
    enum SavedState {
        case saved(URL)
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    var intent: Intent = .profile(.sendIt)

    private var engine: CompressionEngine?
    private var task: Task<Void, Never>?
    private let credits = CreditStore()
    let purchases = PurchaseStore()

    /// The file this run is holding, kept so that a memory warning arriving
    /// mid-compression still has something to hand to the app.
    private var current: ImportedItem?
    private var memoryWatch: [any NSObjectProtocol] = []

    /// Where the incoming file is copied to. The extension's own temporary
    /// directory is fine for input; output has to go to the App Group so the
    /// host app can still read it once we are gone.
    private let inbox: URL

    init() {
        inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        SharedContainer.sweep()
        watchMemory()
    }

    // MARK: - Running out of room

    /// The extension gets a warning shortly before the system kills it. That
    /// warning is the last moment we can still draw anything, so we spend it
    /// stopping the work and offering the app — which is what would have
    /// happened anyway, except visibly and with the file preserved.
    private func watchMemory() {
        let names: [Notification.Name] = [
            UIApplication.didReceiveMemoryWarningNotification,
            ShareViewController.memoryPressure
        ]
        memoryWatch = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.backOff() }
            }
        }
    }

    private func backOff() {
        guard case .working = phase, let item = current else { return }
        cancel()
        phase = .handOff(item, "This one needs more room than the share sheet has. Smaller will open and finish it.")
    }

    // MARK: - Loading

    func load(from providers: [NSItemProvider]) {
        task = Task { [weak self] in
            guard let self else { return }
            guard !providers.isEmpty else {
                self.phase = .failed(Failure("Nothing came through with that share."))
                return
            }
            guard let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
            }) else {
                self.phase = .failed(Failure("That doesn't look like a PDF."))
                return
            }

            ShareLiveness.mark(.reading)
            let item: ImportedItem
            do {
                item = try await self.copyIn(provider)
            } catch {
                self.phase = .failed(Failure("We couldn't read that PDF.", underlying: error))
                return
            }
            self.current = item

            do {
                let engine = try self.makeEngine()
                let inventory = try await engine.inventory(url: item.url)

                if inventory.isLocked {
                    self.phase = .failed(Failure(UnchangedReason.encrypted.userMessage))
                    return
                }
                // Decided before any work starts, so we never begin something
                // the extension's memory budget cannot finish.
                guard ShareBudget.canRunInExtension(inventory) else {
                    self.phase = .handOff(item, "This one's big. Smaller will open and handle it.")
                    return
                }
                if await self.credits.isExhausted, await !self.purchases.isPro {
                    self.phase = .paywall(item, inventory)
                    return
                }
                self.phase = .ready(item, inventory)
            } catch {
                self.phase = .failed(Failure("We couldn't make sense of that PDF.", underlying: error))
            }
            ShareLiveness.clear()
        }
    }

    private func copyIn(_ provider: NSItemProvider) async throws -> ImportedItem {
        let source: URL = try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
                if let url {
                    // The URL is only valid inside this callback, so the copy
                    // has to happen here rather than after it returns.
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent("share-inbox", isDirectory: true)
                        .appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.removeItem(at: destination)
                    do {
                        try FileManager.default.copyItem(at: url, to: destination)
                        continuation.resume(returning: destination)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileNoSuchFile))
                }
            }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int) ?? 0
        return ImportedItem(url: source, displayName: source.lastPathComponent, byteSize: size)
    }

    // MARK: - Compressing

    func start() {
        guard case .ready(let item, _) = phase else { return }
        let intent = self.intent
        phase = .working(0)
        ShareLiveness.mark(.compressing)

        task = Task { [weak self] in
            guard let self else { return }
            defer { ShareLiveness.clear() }
            do {
                let engine = try self.makeEngine()
                let events = switch intent {
                case .profile(let profile): engine.events(url: item.url, profile: profile)
                case .target(let bytes): engine.events(url: item.url, targetBytes: bytes)
                }
                for try await event in events {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .progress(let progress):
                        if case .working(let current) = self.phase {
                            self.phase = .working(max(current, progress.fraction))
                        }
                    case .finished(let outcome):
                        await self.finish(outcome, item: item)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self.phase = .failed(Failure("Something went wrong compressing that file.", underlying: error))
            }
        }
    }

    private func finish(_ outcome: CompressionOutcome, item: ImportedItem) async {
        switch outcome {
        case .compressed(let result), .bestEffort(let result, _):
            // The user's copy first. Whatever the host app does or does not do
            // with what we hand back, this one is theirs.
            let saved = keep(result, originalName: item.displayName)

            let attachment: URL
            do {
                attachment = try deliver(result, originalName: item.displayName)
            } catch {
                phase = .failed(Failure(
                    "We made it smaller but couldn't hand it back.",
                    underlying: error
                ))
                return
            }
            // Only a real file costs a credit.
            await credits.spend()
            phase = .finished(Delivered(result: result, attachment: attachment, saved: saved))
        case .unchanged(let reason):
            phase = .failed(Failure(reason.userMessage))
        }
    }

    /// Copies the result into the App Group, under the name the user would
    /// expect, so the host app can read it after this extension goes away.
    /// Puts a copy where the user will still be able to find it tomorrow.
    ///
    /// An extension cannot write into the app's Files folder — separate
    /// sandboxes — so it stages into the App Group and the app files it on its
    /// next launch. Nothing is lost either way; only the moment it becomes
    /// visible in Files differs, and the result screen says so.
    private func keep(_ result: CompressedResult, originalName: String) -> SavedState {
        do {
            let landed = try FilesLibrary.stage(
                result.url, as: FilesLibrary.outputName(for: originalName)
            )
            return .saved(landed)
        } catch {
            return .failed((error as NSError).localizedDescription)
        }
    }

    private func deliver(_ result: CompressedResult, originalName: String) throws -> URL {
        guard let directory = SharedContainer.outputDirectory() else {
            throw CocoaError(.fileNoSuchFile)
        }
        let destination = directory.appendingPathComponent(
            FilesLibrary.outputName(for: originalName)
        )
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: result.url, to: destination)
        return destination
    }

    // MARK: - Handing over to the app

    /// Puts the file where the app can find it and returns the URL that opens
    /// the app on it.
    func handOffURL(for item: ImportedItem) -> URL? {
        guard let directory = SharedContainer.handoffDirectory() else {
            // The App Group is the only road between here and the app. Without
            // it there is nothing to hand over and nowhere to hand it.
            phase = .failed(Failure("Smaller can't reach its own storage, so it can't pass this to the app."))
            return nil
        }
        let destination = directory.appendingPathComponent(item.displayName)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: item.url, to: destination)
        } catch {
            phase = .failed(Failure("We couldn't pass that file to the app.", underlying: error))
            return nil
        }

        var components = URLComponents()
        components.scheme = "smaller"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "name", value: item.displayName)]
        return components.url
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Called when the sheet closes, however it closes.
    func tearDown() {
        cancel()
        for token in memoryWatch { NotificationCenter.default.removeObserver(token) }
        memoryWatch = []
        let engine = self.engine
        Task { await engine?.discardOutputs() }
        try? FileManager.default.removeItem(at: inbox)
        ShareLiveness.clear()
    }

    func creditsRemaining() async -> Int {
        await credits.remaining
    }

    func markPurchased() {
        if case .paywall(let item, let inventory) = phase {
            phase = .ready(item, inventory)
        }
    }

    private func makeEngine() throws -> CompressionEngine {
        if let engine { return engine }
        let made = try CompressionEngine()
        engine = made
        return made
    }
}
