import Foundation
import CoreGraphics

/// Progress for a running compression.
///
/// It carries the pass number as well as the fraction, because a target-size run
/// on pass 2 needs the UI to say *why* it is still going rather than looking hung.
public struct CompressionProgress: Sendable {
    public let fraction: Double
    public let pass: Int
    public let maxPasses: Int
    /// True once we are past the first attempt at hitting a byte target.
    public var isConverging: Bool { pass > 1 }
}

/// Emitted by the streaming API: progress until the work finishes, then one
/// final outcome.
public enum CompressionEvent: Sendable {
    case progress(CompressionProgress)
    case finished(CompressionOutcome)
}

/// The engine. Everything happens on this actor, which is to say off the main
/// actor, and every step polls for cancellation.
public actor CompressionEngine {

    /// Hard cap on target-size convergence passes.
    public static let maxPasses = 4

    /// Output at or above this fraction of the input is not worth shipping.
    public static let sizeGateThreshold = 0.98

    /// A landing between this fraction of the target and the target itself is
    /// "good" — close enough that another pass would only cost quality.
    public static let goodLandingFloor = 0.80

    /// Below this we are being needlessly ugly and step back up once.
    public static let steppingUpCeiling = 0.60

    private struct CacheKey: Hashable {
        let path: String
        let size: Int
        let modified: Date?
    }

    private var inventoryCache: [CacheKey: PDFInventory] = [:]
    /// Holds produced files alive. Intermediate passes live in a per-run
    /// workspace that is torn down as soon as a winner is picked.
    private let outputs: TempWorkspace
    private var outputCounter = 0

    public init() throws {
        self.outputs = try TempWorkspace(name: "smaller-out")
    }

    /// Drops every file this engine produced. Call when the user leaves the
    /// Done screen.
    public func discardOutputs() {
        outputs.discardAll(except: nil)
    }

    // MARK: - Inventory

    /// Parses the document once and remembers it, so the four passes of a
    /// target-size run never re-parse.
    public func inventory(url: URL) throws -> PDFInventory {
        let key = cacheKey(for: url)
        if let cached = inventoryCache[key] { return cached }
        let built = try InventoryBuilder.build(url: url)
        inventoryCache[key] = built
        for (identity, usage) in built.uniqueImages {
            declinedByteLookup[identity] = usage.totalByteLength
        }
        return built
    }

    private func cacheKey(for url: URL) -> CacheKey {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return CacheKey(
            path: url.standardizedFileURL.path,
            size: attributes?[.size] as? Int ?? 0,
            modified: attributes?[.modificationDate] as? Date
        )
    }

    // MARK: - Compress to a profile

    public func compress(
        url: URL,
        profile: CompressionProfile,
        progress: @Sendable (CompressionProgress) -> Void = { _ in }
    ) throws -> CompressionOutcome {
        let start = Date()
        let inventory = try inventory(url: url)

        if let refusal = earlyRefusal(inventory) { return .unchanged(reason: refusal) }

        let workspace = try TempWorkspace(name: "smaller-pass")
        defer { workspace.cleanUp() }

        let pass: PassResult
        do {
            pass = try runPass(
                inventory: inventory,
                profile: profile,
                output: workspace.url(forPass: 1),
                progressRange: 0...0.9,
                passNumber: 1,
                maxPasses: 1,
                progress: progress
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A PDF we cannot rebuild is a PDF we hand back untouched. The user
            // gets their original file and a straight answer, never a crash.
            return .unchanged(reason: .unsupported("\(error)"))
        }

        guard pass.bytes < Int(Double(inventory.byteSize) * Self.sizeGateThreshold) else {
            return .unchanged(reason: .alreadyOptimized)
        }

        if let failure = try verify(pass.url, inventory: inventory) {
            return .unchanged(reason: .failedIntegrity(failure))
        }
        progress(CompressionProgress(fraction: 1, pass: 1, maxPasses: 1))

        let final = try adopt(pass.url, originalName: url)
        return .compressed(CompressedResult(
            url: final,
            originalBytes: inventory.byteSize,
            finalBytes: pass.bytes,
            profile: profile,
            pageCount: inventory.pageCount,
            passes: 1,
            elapsed: Date().timeIntervalSince(start),
            warnings: warnings(from: pass.stats, inventory: inventory),
            savings: savings(from: pass.stats),
            pageSimilarity: lastSimilarity
        ))
    }

    // MARK: - Compress to a byte target

    /// Iterative convergence, capped at four passes. The inventory is parsed
    /// once and reused; each pass measures rather than predicts.
    public func compress(
        url: URL,
        targetBytes: Int,
        progress: @Sendable (CompressionProgress) -> Void = { _ in }
    ) throws -> CompressionOutcome {
        let start = Date()
        let inventory = try inventory(url: url)

        if inventory.isEncrypted { return .unchanged(reason: .encrypted) }
        if inventory.byteSize <= targetBytes { return .unchanged(reason: .alreadySmall) }

        let workspace = try TempWorkspace(name: "smaller-target")
        defer { workspace.cleanUp() }

        var profile = SizeEstimator.startingProfile(inventory: inventory, targetBytes: targetBytes)
        var bestFitting: (url: URL, bytes: Int, profile: CompressionProfile, stats: PDFRebuilder.Stats)?
        var smallest: (url: URL, bytes: Int, profile: CompressionProfile, stats: PDFRebuilder.Stats)?
        var hasSteppedUp = false
        var passesUsed = 0

        // Rearranging bytes always beats degrading them. If simply storing every
        // repeated image once is enough to clear the target, take that and stop
        // — there is no reason to throw away a single pixel.
        if inventory.duplicateImageBytes > 0 {
            profile = .lossless
        }

        // Text, fonts and vector art are a floor we cannot compress past. If
        // they already exceed the target, go straight to the floor settings and
        // report honestly rather than burning four passes discovering it.
        let unreachable = inventory.nonImageBytes >= targetBytes
        if unreachable {
            profile = .custom(dpi: CompressionProfile.Floor.dpi, quality: CompressionProfile.Floor.quality, grayscale: true)
        }

        for pass in 1...Self.maxPasses {
            passesUsed = pass
            let span = 1.0 / Double(Self.maxPasses)
            let lower = Double(pass - 1) * span
            let result: PassResult
            do {
                result = try runPass(
                    inventory: inventory,
                    profile: profile,
                    output: workspace.url(forPass: pass),
                    progressRange: lower...(lower + span * 0.95),
                    passNumber: pass,
                    maxPasses: Self.maxPasses,
                    progress: progress
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Keep whatever earlier passes produced rather than losing the
                // run to one bad attempt.
                if bestFitting == nil && smallest == nil {
                    return .unchanged(reason: .unsupported("\(error)"))
                }
                passesUsed = max(1, pass - 1)
                break
            }

            if result.bytes <= targetBytes {
                if bestFitting == nil || result.bytes > bestFitting!.bytes {
                    bestFitting = (result.url, result.bytes, profile, result.stats)
                }
            }
            if smallest == nil || result.bytes < smallest!.bytes {
                smallest = (result.url, result.bytes, profile, result.stats)
            }

            let ratio = Double(result.bytes) / Double(targetBytes)

            // Lossless cleared the target. Nothing beats keeping every pixel,
            // however far under we landed, so stop here rather than "improving"
            // quality that was never reduced.
            if !profile.recodesImages && result.bytes <= targetBytes { break }

            if result.bytes <= targetBytes && ratio >= Self.goodLandingFloor { break }
            if unreachable || profile.isAtFloor && result.bytes > targetBytes { break }
            if pass == Self.maxPasses { break }

            if result.bytes > targetBytes {
                // Lossless was not enough; start recoding from a measured base.
                profile = profile.recodesImages
                    ? tightened(profile, inventory: inventory, achieved: result.bytes, target: targetBytes)
                    : SizeEstimator.startingProfile(inventory: inventory, targetBytes: targetBytes)
            } else {
                // Comfortably under: one step back up so we do not hand back
                // needlessly ugly output. Only ever once, to avoid oscillating.
                guard !hasSteppedUp, ratio < Self.steppingUpCeiling else { break }
                hasSteppedUp = true
                profile = loosened(profile, achieved: result.bytes, target: targetBytes)
            }
        }

        guard let winner = bestFitting ?? smallest else {
            return .unchanged(reason: .unsupported("no pass produced output"))
        }

        // A "win" that is bigger than the original is not a win.
        guard winner.bytes < Int(Double(inventory.byteSize) * Self.sizeGateThreshold) else {
            return .unchanged(reason: .alreadyOptimized)
        }

        if let failure = try verify(winner.url, inventory: inventory) {
            return .unchanged(reason: .failedIntegrity(failure))
        }
        progress(CompressionProgress(fraction: 1, pass: passesUsed, maxPasses: Self.maxPasses))

        var collected = warnings(from: winner.stats, inventory: inventory)
        let met = winner.bytes <= targetBytes
        if !met { collected.append(.hitReadabilityFloor) }

        let final = try adopt(winner.url, originalName: url)
        let result = CompressedResult(
            url: final,
            originalBytes: inventory.byteSize,
            finalBytes: winner.bytes,
            profile: winner.profile,
            pageCount: inventory.pageCount,
            passes: passesUsed,
            elapsed: Date().timeIntervalSince(start),
            warnings: collected,
            savings: savings(from: winner.stats),
            pageSimilarity: lastSimilarity
        )
        return met ? .compressed(result) : .bestEffort(result, target: targetBytes)
    }

    // MARK: - Convergence arithmetic

    /// Overshot the target. Images cost roughly (pixels x quality), and pixels
    /// go as DPI squared, so DPI moves by the square root of the shortfall while
    /// quality takes a gentler cut.
    private func tightened(
        _ profile: CompressionProfile,
        inventory: PDFInventory,
        achieved: Int,
        target: Int
    ) -> CompressionProfile {
        let imageBudget = Double(max(1, target - inventory.nonImageBytes))
        let achievedImages = Double(max(1, achieved - inventory.nonImageBytes))
        let need = min(1.0, max(0.05, imageBudget / achievedImages))

        let dpi = profile.targetDPI * max(0.55, need.squareRoot())
        let quality = profile.jpegQuality * max(0.75, pow(need, 0.25))
        return .custom(dpi: dpi, quality: quality, grayscale: dpi <= 90 || profile.allowsGrayscaleForScans)
    }

    /// Landed well under the target — recover some quality, aiming at 90% of it.
    private func loosened(_ profile: CompressionProfile, achieved: Int, target: Int) -> CompressionProfile {
        let room = min(2.0, (Double(target) * 0.9) / Double(max(1, achieved)))
        return .custom(
            dpi: profile.targetDPI * room.squareRoot(),
            quality: min(CompressionProfile.Ceiling.quality, profile.jpegQuality * pow(room, 0.25)),
            grayscale: false
        )
    }

    // MARK: - One pass

    private struct PassResult {
        let url: URL
        let bytes: Int
        let stats: PDFRebuilder.Stats
    }

    private func runPass(
        inventory: PDFInventory,
        profile: CompressionProfile,
        output: URL,
        progressRange: ClosedRange<Double>,
        passNumber: Int,
        maxPasses: Int,
        progress: @Sendable (CompressionProgress) -> Void
    ) throws -> PassResult {
        try Task.checkCancellation()
        guard let document = CGPDFDocument(inventory.url as CFURL) else {
            throw InventoryBuilder.BuildError.cannotOpen(inventory.url)
        }

        let rebuilder = try PDFRebuilder(
            document: document,
            inventory: inventory,
            profile: profile,
            outputURL: output
        )

        let span = progressRange.upperBound - progressRange.lowerBound
        do {
            let stats = try rebuilder.run(
                progress: { fraction in
                    progress(CompressionProgress(
                        fraction: progressRange.lowerBound + fraction * span,
                        pass: passNumber,
                        maxPasses: maxPasses
                    ))
                },
                checkpoint: { try Task.checkCancellation() }
            )
            return PassResult(url: output, bytes: FileSize.bytes(at: output), stats: stats)
        } catch {
            rebuilder.abandon()
            throw error
        }
    }

    // MARK: - Gates

    private func earlyRefusal(_ inventory: PDFInventory) -> UnchangedReason? {
        if inventory.isEncrypted { return .encrypted }
        if let loss = objectLossRefusal(inventory) { return loss }
        if !inventory.isWorthCompressing { return .alreadySmall }
        return nil
    }

    /// Refuses files where CoreGraphics cannot see everything that is in them.
    ///
    /// A damaged cross-reference table leaves CoreGraphics able to open the file
    /// and resolve *some* of its objects. Anything we rebuild from that view is
    /// missing whatever it could not reach, and because our own verification
    /// renders the original through the same CoreGraphics, it cannot see the
    /// gap either. Counting the image objects in the raw bytes is the only
    /// independent check available, and when it disagrees we decline rather than
    /// hand back a file that quietly lost a slide's artwork.
    private func objectLossRefusal(_ inventory: PDFInventory) -> UnchangedReason? {
        guard inventory.rawImageObjectCount > 0, inventory.hasUnresolvedObjects else { return nil }

        // Generous slack. The census counts every `/Subtype /Image` in the raw
        // bytes, which legitimately overcounts: incremental updates supersede
        // objects, and images can hide behind annotation appearance streams or
        // patterns that the resource walk does not follow. We are looking for
        // wholesale loss, not an off-by-a-few.
        let missed = Double(inventory.unresolvedImageObjects) / Double(inventory.rawImageObjectCount)
        guard missed > Self.objectLossTolerance else { return nil }

        return .unsupported(
            "damaged cross-reference table: \(inventory.unresolvedImageObjects) of "
            + "\(inventory.rawImageObjectCount) image objects could not be resolved"
        )
    }

    /// Fraction of image objects we allow to go unresolved before refusing.
    public static let objectLossTolerance = 0.25

    /// Lowest page correlation from the most recent verification.
    private var lastSimilarity: Double = 1

    /// Returns the failure, or nil when the output is sound.
    private func verify(_ output: URL, inventory: PDFInventory) throws -> IntegrityFailure? {
        let inputHasText = inventory.hasEmbeddedText
            && IntegrityGate.inputHasText(url: inventory.url, pageCount: inventory.pageCount)

        let report = try IntegrityGate.check(
            original: inventory.url,
            output: output,
            expectedPageCount: inventory.pageCount,
            inputHadText: inputHasText,
            checkpoint: { try Task.checkCancellation() }
        )
        lastSimilarity = 1.0 - report.worstDivergence
        return report.passed ? nil : (report.failure ?? .cannotReopen)
    }

    /// Moves a winning pass out of its scratch workspace, where it would be
    /// deleted, and into the engine's own.
    private func adopt(_ url: URL, originalName: URL) throws -> URL {
        outputCounter += 1
        let base = originalName.deletingPathExtension().lastPathComponent
        let destination = outputs.url(named: "\(base)-smaller-\(outputCounter).pdf")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    private func savings(from stats: PDFRebuilder.Stats) -> SavingsBreakdown {
        // Counted per distinct image, not per placement: a logo declined on
        // every slide is one image we could not take on, not fourteen.
        var byReason: [DeclineReason: Int] = [:]
        var bytesByReason: [DeclineReason: Int] = [:]
        var distinctDeclines = 0
        var distinctDeclinedBytes = 0
        for (identity, decision) in stats.decisions {
            guard case .declined(let reason) = decision else { continue }
            byReason[reason, default: 0] += 1
            let bytes = declinedBytes(for: identity)
            bytesByReason[reason, default: 0] += bytes
            distinctDeclines += 1
            distinctDeclinedBytes += bytes
        }
        return SavingsBreakdown(
            dedupBytes: stats.dedupBytes,
            recodeBytes: stats.recodeBytes,
            imagesRecoded: stats.imagesRecoded,
            masksRecoded: stats.masksRecoded,
            imagePlacementsDeduplicated: stats.imagesDeduplicated,
            streamsDeduplicated: stats.streamsDeduplicated,
            imagesDeclined: distinctDeclines,
            declinedBytes: distinctDeclinedBytes,
            declinesByReason: byReason,
            declinedBytesByReason: bytesByReason
        )
    }

    /// Bytes attributable to one declined image, looked up in the cached
    /// inventory so the report can total the decline list.
    private var declinedByteLookup: [ImageIdentity: Int] = [:]

    private func declinedBytes(for identity: ImageIdentity) -> Int {
        declinedByteLookup[identity] ?? 0
    }

    private func warnings(from stats: PDFRebuilder.Stats, inventory: PDFInventory) -> [CompressionWarning] {
        var out: [CompressionWarning] = []
        if inventory.hasFormFields { out.append(.formFieldsPresent) }
        if inventory.hasUnresolvedObjects {
            out.append(.possibleObjectLoss(
                missing: inventory.unresolvedImageObjects,
                of: inventory.rawImageObjectCount
            ))
        }
        if stats.imagesDeclined > 0 {
            out.append(.imagesSkipped(count: stats.imagesDeclined, bytes: stats.declinedBytes))
        }
        if stats.pagesRasterized > 0 {
            out.append(.pagesRasterized(count: stats.pagesRasterized))
        }
        for fallback in stats.rasterFallbacks {
            out.append(.pageFellBackToRaster(page: fallback.page, reason: fallback.reason))
        }
        return out
    }
}

// MARK: - Streaming API

extension CompressionEngine {

    /// Progress as an `AsyncStream`, finishing with the outcome.
    ///
    /// Cancelling the consuming task cancels the work, and every intermediate
    /// file is removed on the way out.
    public nonisolated func events(
        url: URL,
        profile: CompressionProfile
    ) -> AsyncThrowingStream<CompressionEvent, Error> {
        stream { engine, emit in
            try await engine.compress(url: url, profile: profile, progress: emit)
        }
    }

    public nonisolated func events(
        url: URL,
        targetBytes: Int
    ) -> AsyncThrowingStream<CompressionEvent, Error> {
        stream { engine, emit in
            try await engine.compress(url: url, targetBytes: targetBytes, progress: emit)
        }
    }

    private nonisolated func stream(
        _ work: @escaping @Sendable (CompressionEngine, @escaping @Sendable (CompressionProgress) -> Void) async throws -> CompressionOutcome
    ) -> AsyncThrowingStream<CompressionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let outcome = try await work(self) { progress in
                        continuation.yield(.progress(progress))
                    }
                    continuation.yield(.finished(outcome))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
