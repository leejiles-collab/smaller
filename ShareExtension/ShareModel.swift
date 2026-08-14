import Foundation
import Observation
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
        case finished(CompressedResult, URL)
        /// Too big for the extension's memory budget. Not a failure — the app
        /// can do it, and this offers exactly that.
        case handOff(ImportedItem, String)
        case paywall(ImportedItem, PDFInventory)
        case failed(String)
    }

    struct ImportedItem {
        let url: URL
        let displayName: String
        let byteSize: Int
    }

    private(set) var phase: Phase = .loading
    var intent: Intent = .profile(.sendIt)

    private var engine: CompressionEngine?
    private var task: Task<Void, Never>?
    private let credits = CreditStore()
    let purchases = PurchaseStore()

    /// Where the incoming file is copied to. The extension's own temporary
    /// directory is fine for input; output has to go to the App Group so the
    /// host app can still read it once we are gone.
    private let inbox: URL

    init() {
        inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        SharedContainer.sweep()
    }

    // MARK: - Loading

    func load(from providers: [NSItemProvider]) {
        task = Task { [weak self] in
            guard let self else { return }
            guard let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
            }) else {
                self.phase = .failed("That doesn't look like a PDF.")
                return
            }

            do {
                let item = try await self.copyIn(provider)
                let engine = try self.makeEngine()
                let inventory = try await engine.inventory(url: item.url)

                if inventory.isLocked {
                    self.phase = .failed(UnchangedReason.encrypted.userMessage)
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
                self.phase = .failed("We couldn't read that PDF.")
            }
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

        task = Task { [weak self] in
            guard let self else { return }
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
                self.phase = .failed("Something went wrong compressing that file.")
            }
        }
    }

    private func finish(_ outcome: CompressionOutcome, item: ImportedItem) async {
        switch outcome {
        case .compressed(let result), .bestEffort(let result, _):
            guard let delivered = deliver(result, originalName: item.displayName) else {
                phase = .failed("We couldn't hand the file back.")
                return
            }
            // Only a real file costs a credit.
            await credits.spend()
            phase = .finished(result, delivered)
        case .unchanged(let reason):
            phase = .failed(reason.userMessage)
        }
    }

    /// Copies the result into the App Group, under the name the user would
    /// expect, so the host app can read it after this extension goes away.
    private func deliver(_ result: CompressedResult, originalName: String) -> URL? {
        guard let directory = SharedContainer.outputDirectory() else { return nil }
        let base = (originalName as NSString).deletingPathExtension
        let destination = directory.appendingPathComponent("\(base)-smaller.pdf")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: result.url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    // MARK: - Handing over to the app

    /// Puts the file where the app can find it and returns the URL that opens
    /// the app on it.
    func handOffURL(for item: ImportedItem) -> URL? {
        guard let directory = SharedContainer.handoffDirectory() else { return nil }
        let destination = directory.appendingPathComponent(item.displayName)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: item.url, to: destination)

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
        let engine = self.engine
        Task { await engine?.discardOutputs() }
        try? FileManager.default.removeItem(at: inbox)
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
