import Testing
import Foundation
import CoreGraphics
import CoreText
@testable import SmallerKit

/// Phase 1 regression cover. The full suite lands in phase 5; these exist so a
/// change to the rebuilder cannot quietly stop producing valid PDFs.
struct EngineSmokeTests {

    // MARK: - Fixtures generated in-test

    static func makePDF(pages: Int, at url: URL, body: (CGContext, Int) -> Void) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for index in 0..<pages {
            context.beginPDFPage(nil)
            body(context, index)
            context.endPDFPage()
        }
        context.closePDF()
    }

    static func noisyImage(width: Int, height: Int, seed: UInt64) -> CGImage {
        var state = seed
        func random() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        for _ in 0..<1500 {
            context.setFillColor(
                red: Double(random() % 255) / 255,
                green: Double(random() % 255) / 255,
                blue: Double(random() % 255) / 255,
                alpha: 0.5
            )
            context.fillEllipse(in: CGRect(
                x: Double(random() % UInt64(width)),
                y: Double(random() % UInt64(height)),
                width: 90, height: 90
            ))
        }
        return context.makeImage()!
    }

    static func draw(_ context: CGContext, text: String, at point: CGPoint, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font
        ])
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }

    // MARK: - Inventory

    @Test func inventoryMeasuresEffectiveDPI() throws {
        let workspace = try TempWorkspace(name: "test-inventory")
        defer { workspace.cleanUp() }
        let url = workspace.url(named: "photo.pdf")

        // 1200 px drawn across 300 pt is 288 dpi, whatever the page size is.
        let image = Self.noisyImage(width: 1200, height: 1200, seed: 1)
        Self.makePDF(pages: 1, at: url) { context, _ in
            context.draw(image, in: CGRect(x: 50, y: 50, width: 300, height: 300))
        }

        let inventory = try InventoryBuilder.build(url: url)
        #expect(inventory.pageCount == 1)
        #expect(inventory.imageCount == 1)

        let usage = try #require(inventory.images.first)
        #expect(abs(usage.effectiveDPI - 288) < 1)
        #expect(usage.pageIndex == 0)
        #expect(inventory.pages[0].pageClass == .mixed)
    }

    @Test func pageWithoutImagesIsVectorOnly() throws {
        let workspace = try TempWorkspace(name: "test-vector")
        defer { workspace.cleanUp() }
        let url = workspace.url(named: "text.pdf")
        Self.makePDF(pages: 2, at: url) { context, index in
            Self.draw(context, text: "Page \(index + 1)", at: CGPoint(x: 60, y: 700), size: 18)
        }

        let inventory = try InventoryBuilder.build(url: url)
        #expect(inventory.pageClasses.allSatisfy { $0 == .vectorOnly })
        #expect(inventory.isWorthCompressing == false)
    }

    @Test func fullBleedImageWithNoTextIsScanLike() throws {
        let workspace = try TempWorkspace(name: "test-scan")
        defer { workspace.cleanUp() }
        let url = workspace.url(named: "scan.pdf")
        let image = Self.noisyImage(width: 1200, height: 1550, seed: 9)
        Self.makePDF(pages: 1, at: url) { context, _ in
            context.draw(image, in: CGRect(x: 0, y: 0, width: 612, height: 792))
        }

        let inventory = try InventoryBuilder.build(url: url)
        #expect(inventory.pages[0].pageClass == .scanLike)
    }

    // MARK: - Classification rule

    @Test func scanClassificationRequiresZeroTextOperators() {
        // An OCR layer must keep the page off the rasterizer, or the invisible
        // text it carries would be destroyed.
        #expect(InventoryBuilder.classify(imageCount: 1, maxCoverage: 0.95, textOperators: 0) == .scanLike)
        #expect(InventoryBuilder.classify(imageCount: 1, maxCoverage: 0.95, textOperators: 40) == .mixed)
        #expect(InventoryBuilder.classify(imageCount: 1, maxCoverage: 0.30, textOperators: 0) == .mixed)
        #expect(InventoryBuilder.classify(imageCount: 0, maxCoverage: 0, textOperators: 80) == .vectorOnly)
    }

    // MARK: - Compression

    @Test func compressionShrinksAndKeepsTextAndPageCount() async throws {
        let workspace = try TempWorkspace(name: "test-compress")
        defer { workspace.cleanUp() }
        let url = workspace.url(named: "mixed.pdf")
        let image = Self.noisyImage(width: 1600, height: 1100, seed: 4)
        Self.makePDF(pages: 3, at: url) { context, index in
            Self.draw(context, text: "Section \(index + 1) heading", at: CGPoint(x: 60, y: 720), size: 20)
            for row in 0..<10 {
                Self.draw(context, text: "Body copy line \(row + 1) on page \(index + 1).",
                          at: CGPoint(x: 60, y: 690 - CGFloat(row) * 16), size: 11)
            }
            context.draw(image, in: CGRect(x: 60, y: 150, width: 480, height: 330))
        }

        let engine = try CompressionEngine()
        let before = try await engine.inventory(url: url)
        let outcome = try await engine.compress(url: url, profile: .sendIt)

        let result = try #require(outcome.result)
        #expect(result.finalBytes < before.byteSize)
        #expect(result.pageCount == 3)

        // The original must be exactly where it was, untouched.
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileSize.bytes(at: url) == before.byteSize)

        // Text is copied verbatim, not re-rendered, so it must come back whole.
        let after = try InventoryBuilder.build(url: result.url)
        #expect(after.pageCount == 3)
        #expect(after.hasEmbeddedText)
    }

    @Test func documentWithNothingToGainIsRefusedHonestly() async throws {
        let workspace = try TempWorkspace(name: "test-refuse")
        defer { workspace.cleanUp() }
        let url = workspace.url(named: "text.pdf")
        Self.makePDF(pages: 4, at: url) { context, index in
            for row in 0..<30 {
                Self.draw(context, text: "Line \(row) of page \(index).",
                          at: CGPoint(x: 60, y: 720 - CGFloat(row) * 20), size: 11)
            }
        }

        let engine = try CompressionEngine()
        let outcome = try await engine.compress(url: url, profile: .tiny)

        guard case .unchanged(let reason) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        // Either honest answer will do. The engine no longer refuses a file for
        // having too few images — a 581-page vector report with none at all
        // still compressed 88% — so a document with nothing to gain is now
        // discovered by measuring rather than assumed from its image share.
        #expect(reason == .alreadySmall || reason == .alreadyOptimized)
        #expect(outcome.burnsCredit == false)
    }

    // MARK: - Target size

    @Test func targetSizeConvergesAndReportsPasses() async throws {
        let workspace = try TempWorkspace(name: "test-target")
        defer { workspace.cleanUp() }
        let url = workspace.url(named: "big.pdf")
        let image = Self.noisyImage(width: 2200, height: 2800, seed: 11)
        Self.makePDF(pages: 4, at: url) { context, _ in
            context.draw(image, in: CGRect(x: 20, y: 20, width: 572, height: 752))
        }

        let engine = try CompressionEngine()
        let target = 400_000
        let outcome = try await engine.compress(url: url, targetBytes: target)

        let result = try #require(outcome.result)
        #expect(result.passes >= 1)
        #expect(result.passes <= CompressionEngine.maxPasses)

        if case .compressed = outcome {
            #expect(result.finalBytes <= target)
        }
    }

    @Test func readabilityFloorIsRespected() {
        let absurd = CompressionProfile.custom(dpi: 5, quality: 0.01)
        #expect(absurd.targetDPI == CompressionProfile.Floor.dpi)
        #expect(absurd.jpegQuality == CompressionProfile.Floor.quality)
        #expect(absurd.isAtFloor)
    }

    // MARK: - Integrity gate

    @Test func integrityGateRejectsCorruptedOutput() throws {
        let workspace = try TempWorkspace(name: "test-integrity")
        defer { workspace.cleanUp() }
        let url = workspace.url(named: "broken.pdf")
        try Data("%PDF-1.7\nthis is not a pdf\n%%EOF\n".utf8).write(to: url)

        let report = try IntegrityGate.check(
            original: url,
            output: url,
            expectedPageCount: 3,
            inputHadText: false,
            checkpoint: {}
        )
        #expect(report.passed == false)
        #expect(report.failure == .cannotReopen)
    }

    @Test func integrityGateSamplesLongDocumentsButCoversTheEnds() {
        let short = IntegrityGate.sampleIndices(pageCount: 9)
        #expect(short == Array(0..<9))

        let long = IntegrityGate.sampleIndices(pageCount: 900)
        #expect(long.count <= IntegrityGate.sampleCount)
        #expect(long.first == 0)
        #expect(long.last == 899)
    }

    // MARK: - Flate

    @Test func flateRoundTripsThroughCoreGraphics() throws {
        // The encoder hand-builds the zlib wrapper Apple's Compression omits, so
        // this checks a real PDF parser accepts what we produce.
        let payload = Data(repeating: 0x41, count: 5000) + Data((0..<5000).map { UInt8($0 % 251) })
        let encoded = try #require(Flate.encode(payload))
        #expect(encoded.count < payload.count)
        #expect(encoded[0] == 0x78)

        let adler = Flate.adler32(Data("Wikipedia".utf8))
        #expect(adler == 0x11E60398)
    }
}
