import Testing
import Foundation
import CoreGraphics
@testable import SmallerKit

/// Cover for the two things that decide whether this product works on real
/// exported decks: alpha images must be recoded rather than declined, and
/// content embedded once per slide must be stored once.
struct DedupAndAlphaTests {

    // MARK: - A hand-written PDF

    /// CoreGraphics de-duplicates images as it writes, so it cannot produce the
    /// case we need to test. This writes the bytes directly: a deck that embeds
    /// the same banner once per slide as a separate object every time, exactly
    /// as PowerPoint and Keynote do.
    struct DeckBuilder {
        var data = Data()
        var offsets: [Int: Int] = [:]
        var next = 1

        init() { data.append(Data("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)) }

        mutating func allocate() -> Int { defer { next += 1 }; return next }

        mutating func object(_ number: Int, _ body: String) {
            offsets[number] = data.count
            data.append(Data("\(number) 0 obj\n\(body)\nendobj\n".utf8))
        }

        mutating func stream(_ number: Int, _ dictionary: String, _ payload: Data) {
            offsets[number] = data.count
            data.append(Data("\(number) 0 obj\n<< \(dictionary) /Length \(payload.count) >>\nstream\n".utf8))
            data.append(payload)
            data.append(Data("\nendstream\nendobj\n".utf8))
        }

        /// `damageEvery` corrupts every nth cross-reference entry, reproducing a
        /// file whose table no longer matches its contents.
        mutating func finish(root: Int, damageEvery: Int? = nil) -> Data {
            let tableOffset = data.count
            var text = "xref\n0 \(next)\n0000000000 65535 f \n"
            for number in 1..<next {
                var offset = offsets[number] ?? 0
                if let damageEvery, number % damageEvery == 0 { offset += 17 }
                text += String(format: "%010d 00000 n \n", offset)
            }
            text += "trailer\n<< /Size \(next) /Root \(root) 0 R >>\nstartxref\n\(tableOffset)\n%%EOF\n"
            data.append(Data(text.utf8))
            return data
        }
    }

    /// Uncompressed RGB samples, so the fixture needs no encoder.
    static func rgbSamples(width: Int, height: Int, seed: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            bytes[i * 3] = UInt8((i &* 7 &+ Int(seed)) % 251)
            bytes[i * 3 + 1] = UInt8((i &* 13 &+ Int(seed)) % 241)
            bytes[i * 3 + 2] = UInt8((i &* 29 &+ Int(seed)) % 239)
        }
        return Data(bytes)
    }

    /// A soft mask with a feathered edge, like a real cut-out.
    static func maskSamples(width: Int, height: Int) -> Data {
        var bytes = [UInt8](repeating: 255, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let edge = min(min(x, width - 1 - x), min(y, height - 1 - y))
                if edge < 8 { bytes[y * width + x] = UInt8(edge * 255 / 8) }
            }
        }
        return Data(bytes)
    }

    /// Builds a deck where every slide re-embeds an identical banner (with a
    /// soft mask) plus one image unique to that slide.
    static func makeDeck(
        at url: URL,
        slides: Int,
        withAlpha: Bool = true,
        damageEvery: Int? = nil
    ) throws {
        var builder = DeckBuilder()
        let catalog = builder.allocate()
        let pagesNode = builder.allocate()
        let pageNumbers = (0..<slides).map { _ in builder.allocate() }

        let bannerWidth = 200, bannerHeight = 80
        let banner = rgbSamples(width: bannerWidth, height: bannerHeight, seed: 3)
        let mask = maskSamples(width: bannerWidth, height: bannerHeight)

        for (index, pageNumber) in pageNumbers.enumerated() {
            var bannerDictionary = "/Type /XObject /Subtype /Image /Width \(bannerWidth) "
                + "/Height \(bannerHeight) /ColorSpace /DeviceRGB /BitsPerComponent 8"

            if withAlpha {
                let maskNumber = builder.allocate()
                builder.stream(maskNumber, "/Type /XObject /Subtype /Image /Width \(bannerWidth) "
                    + "/Height \(bannerHeight) /ColorSpace /DeviceGray /BitsPerComponent 8", mask)
                bannerDictionary += " /SMask \(maskNumber) 0 R"
            }

            let bannerNumber = builder.allocate()
            builder.stream(bannerNumber, bannerDictionary, banner)

            let unique = rgbSamples(width: 120, height: 90, seed: UInt8(index % 200 + 1))
            let uniqueNumber = builder.allocate()
            builder.stream(uniqueNumber, "/Type /XObject /Subtype /Image /Width 120 "
                + "/Height 90 /ColorSpace /DeviceRGB /BitsPerComponent 8", unique)

            let content = "q 400 0 0 160 20 300 cm /Banner Do Q\nq 240 0 0 180 20 60 cm /Unique Do Q\n"
            let contentNumber = builder.allocate()
            builder.stream(contentNumber, "", Data(content.utf8))

            builder.object(pageNumber, """
            << /Type /Page /Parent \(pagesNode) 0 R /MediaBox [0 0 480 540] \
            /Resources << /XObject << /Banner \(bannerNumber) 0 R /Unique \(uniqueNumber) 0 R >> >> \
            /Contents \(contentNumber) 0 R >>
            """)
        }

        builder.object(pagesNode, "<< /Type /Pages /Kids ["
            + pageNumbers.map { "\($0) 0 R" }.joined(separator: " ")
            + "] /Count \(slides) >>")
        builder.object(catalog, "<< /Type /Catalog /Pages \(pagesNode) 0 R >>")

        try builder.finish(root: catalog, damageEvery: damageEvery).write(to: url)
    }

    // MARK: - Duplicate detection

    @Test func identicalEmbedsAreCountedAsOneContent() throws {
        let workspace = try TempWorkspace(name: "test-dupes")
        defer { workspace.cleanUp() }
        let url = workspace.url(named: "deck.pdf")
        try Self.makeDeck(at: url, slides: 8)

        let inventory = try InventoryBuilder.build(url: url)

        // Sixteen placements: a banner and a unique image on each of eight slides.
        #expect(inventory.imageCount == 16)
        // Nine distinct pictures: eight unique ones plus the single banner.
        #expect(inventory.uniqueImages.count == 9)
        // Seven redundant copies of the banner and its mask.
        #expect(inventory.duplicateImageBytes > 0)
        #expect(inventory.uniqueImageBytes < inventory.imageObjectBytes)
    }

    @Test func losslessProfileRecoversDuplicatesWithoutRecoding() async throws {
        let workspace = try TempWorkspace(name: "test-lossless")
        defer { workspace.cleanUp() }
        let url = workspace.url(named: "deck.pdf")
        try Self.makeDeck(at: url, slides: 10)

        let engine = try CompressionEngine()
        let outcome = try await engine.compress(url: url, profile: .lossless)
        let result = try #require(outcome.result)

        #expect(result.finalBytes < result.originalBytes)
        // Lossless means exactly that: bytes rearranged, no image touched.
        #expect(result.savings.recodeBytes == 0)
        #expect(result.savings.imagesRecoded == 0)
        #expect(result.savings.dedupBytes > 0)
    }

    // MARK: - Alpha

    @Test func alphaImagesAreRecodedRatherThanDeclined() async throws {
        let workspace = try TempWorkspace(name: "test-alpha")
        defer { workspace.cleanUp() }
        let url = workspace.url(named: "deck.pdf")
        try Self.makeDeck(at: url, slides: 6, withAlpha: true)

        let inventory = try InventoryBuilder.build(url: url)
        let banner = try #require(inventory.images.first { $0.mask != nil })

        // The whole point of this phase: alpha is no longer a refusal.
        #expect(banner.isRecodable)
        #expect(banner.declineReason == nil)

        let engine = try CompressionEngine()
        let outcome = try await engine.compress(url: url, profile: .small)
        let result = try #require(outcome.result)

        #expect(result.savings.imagesRecoded > 0)
        // A recoded alpha image must come with a rebuilt mask, or it would have
        // lost its transparency.
        #expect(result.savings.masksRecoded > 0)
    }

    @Test func recodedAlphaImageKeepsItsSoftMask() async throws {
        let workspace = try TempWorkspace(name: "test-alpha-mask")
        defer { workspace.cleanUp() }
        let url = workspace.url(named: "deck.pdf")
        try Self.makeDeck(at: url, slides: 4, withAlpha: true)

        let engine = try CompressionEngine()
        let outcome = try await engine.compress(url: url, profile: .small)
        let result = try #require(outcome.result)

        let after = try InventoryBuilder.build(url: result.url)
        let withMask = after.images.filter { $0.mask != nil }
        #expect(!withMask.isEmpty, "transparency was dropped on the way out")

        // The rebuilt mask is 8-bit grey, whatever the source was.
        for image in withMask {
            #expect(image.mask?.bitsPerComponent == 8)
            #expect(image.mask?.hasMatte == false)
        }
    }

    @Test func premultipliedAlphaIsLeftAlone() {
        let matte = MaskInfo(pixelWidth: 10, pixelHeight: 10, bitsPerComponent: 8,
                             encodedLength: 100, hasMatte: true, hasDecodeArray: false, isStencil: false)
        let usage = ImageUsage(
            identity: ImageIdentity(hex: "abc"), key: ImageKey(pixelWidth: 10, pixelHeight: 10,
            bitsPerComponent: 8, encodedLength: 100, filter: "FlateDecode"),
            pageIndex: 0, pixelWidth: 10, pixelHeight: 10, bitsPerComponent: 8,
            componentCount: 3, colorSpaceName: "DeviceRGB", filter: .flate, rawByteLength: 100,
            drawnWidthPoints: 100, drawnHeightPoints: 100, mask: matte,
            hasColourKeyMask: false, hasDecodeArray: false, isStencilMask: false
        )
        // Un-premultiplying is guesswork, so we decline instead of guessing.
        #expect(usage.declineReason == .matte)
    }

    // MARK: - Stencil masks

    @Test func stencilSamplesInvertIntoASoftMask() throws {
        // In a stencil `/Mask`, a sample of 1 means masked *out*; in an
        // `/SMask`, 255 means fully opaque. The unpack has to flip that.
        let packed = Data([0b1010_0000])
        let expanded = try #require(
            ImageRecoder.unpack(packed, width: 4, height: 1, bitsPerComponent: 1, invert: true)
        )
        #expect(expanded == [0, 255, 0, 255])

        let straight = try #require(
            ImageRecoder.unpack(packed, width: 4, height: 1, bitsPerComponent: 1, invert: false)
        )
        #expect(straight == [255, 0, 255, 0])
    }

    // MARK: - Damaged cross-reference tables

    @Test func rawCensusSeesEveryImageObjectInTheFile() throws {
        let workspace = try TempWorkspace(name: "test-census")
        defer { workspace.cleanUp() }
        let url = workspace.url(named: "deck.pdf")
        try Self.makeDeck(at: url, slides: 5, withAlpha: true)

        // Five slides, each with a banner, its mask, and a unique image.
        #expect(RawCensus.imageObjectCount(url: url) == 15)

        let inventory = try InventoryBuilder.build(url: url)
        #expect(inventory.resolvedImageObjectCount == 15)
        #expect(inventory.hasUnresolvedObjects == false)
        #expect(inventory.xrefWasRepaired == false)
    }

    @Test func damagedCrossReferenceTableIsDetectedAndRefused() async throws {
        let workspace = try TempWorkspace(name: "test-damaged")
        defer { workspace.cleanUp() }
        let url = workspace.url(named: "damaged.pdf")
        try Self.makeDeck(at: url, slides: 8, withAlpha: true, damageEvery: 3)

        let inventory = try InventoryBuilder.build(url: url)
        #expect(inventory.xrefWasRepaired, "a table full of wrong offsets went unnoticed")

        // CoreGraphics opens the file and reports its pages, but cannot reach
        // every object — and never says which. The census is what catches it.
        #expect(inventory.hasUnresolvedObjects)

        let engine = try CompressionEngine()
        let outcome = try await engine.compress(url: url, profile: .small)

        guard case .unchanged(let reason) = outcome else {
            Issue.record("rebuilt a file we cannot fully read: \(outcome)")
            return
        }
        guard case .unsupported(let detail) = reason else {
            Issue.record("expected an unsupported refusal, got \(reason)")
            return
        }
        #expect(detail.contains("cross-reference"))
        #expect(outcome.burnsCredit == false)
    }

    // MARK: - Page divergence

    @Test func divergenceSpotsAPageThatLostItsArtwork() throws {
        let workspace = try TempWorkspace(name: "test-divergence")
        defer { workspace.cleanUp() }

        let full = workspace.url(named: "full.pdf")
        let empty = workspace.url(named: "empty.pdf")
        try Self.makeDeck(at: full, slides: 2, withAlpha: false)

        // Same page geometry, no artwork at all.
        var builder = DeckBuilder()
        let catalog = builder.allocate()
        let pagesNode = builder.allocate()
        let pageNumbers = [builder.allocate(), builder.allocate()]
        for pageNumber in pageNumbers {
            builder.object(pageNumber, "<< /Type /Page /Parent \(pagesNode) 0 R /MediaBox [0 0 480 540] >>")
        }
        builder.object(pagesNode, "<< /Type /Pages /Kids ["
            + pageNumbers.map { "\($0) 0 R" }.joined(separator: " ") + "] /Count 2 >>")
        builder.object(catalog, "<< /Type /Catalog /Pages \(pagesNode) 0 R >>")
        try builder.finish(root: catalog).write(to: empty)

        let report = try IntegrityGate.check(
            original: full,
            output: empty,
            expectedPageCount: 2,
            inputHadText: false,
            checkpoint: {}
        )
        #expect(report.passed == false)
    }

    @Test func honestCompressionStaysWellInsideTheDivergenceBudget() async throws {
        let workspace = try TempWorkspace(name: "test-divergence-ok")
        defer { workspace.cleanUp() }
        let url = workspace.url(named: "deck.pdf")
        try Self.makeDeck(at: url, slides: 4, withAlpha: true)

        let engine = try CompressionEngine()
        // `.tiny` is the most aggressive thing we ship. If that trips the gate,
        // the threshold is wrong.
        let outcome = try await engine.compress(url: url, profile: .tiny)
        #expect(outcome.result != nil, "the divergence gate rejected honest compression")
    }
}
