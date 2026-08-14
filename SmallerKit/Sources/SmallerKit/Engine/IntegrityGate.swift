import Foundation
import CoreGraphics
import PDFKit

/// Proves the output is a real, readable PDF before we let anyone see it.
///
/// If any check fails the output is thrown away and the original is returned.
/// A file that is smaller but broken is worse than no compression at all.
enum IntegrityGate {

    /// Rendering every page of a 900-page scan would take longer than the
    /// compression did. Short documents are checked exhaustively; long ones are
    /// sampled, always including the first and last page.
    static let exhaustiveCheckLimit = 25
    static let sampleCount = 12

    /// How much a rendered page may stop *correlating* with the original before
    /// we call it content loss rather than compression.
    ///
    /// Correlation rather than pixel difference, deliberately. Compression
    /// legitimately shifts brightness and contrast — converting a page to
    /// greyscale moves every pixel — and an absolute-difference test flags that
    /// as damage. Measured on the fixture set, honest output at `.tiny` still
    /// correlates above 0.97 with its source, while a page that lost its artwork
    /// falls off a cliff. There is a lot of daylight between those.
    static let minPageCorrelation = 0.75

    /// Pages are rendered at this size, then box-averaged down to
    /// `comparisonSide` by us.
    ///
    /// Letting CoreGraphics do the whole reduction in one step is not good
    /// enough: even at high interpolation quality it aliases, and on a noisy
    /// scan the aliasing dominates the signal — two renders of the same page
    /// were correlating at 0.41. Averaging exact blocks removes the grain and
    /// leaves the structure, which is the only thing we want to compare.
    static let renderSide = 256
    static let comparisonSide = 32

    struct Report {
        let passed: Bool
        let failure: IntegrityFailure?
        let pagesChecked: Int
        let textSurvived: Bool
        /// Largest per-page divergence observed, for calibration.
        let worstDivergence: Double
    }

    static func check(
        original: URL,
        output: URL,
        expectedPageCount: Int,
        inputHadText: Bool,
        checkpoint: () throws -> Void
    ) throws -> Report {
        guard let document = PDFOpen.document(at: output) else {
            return Report(passed: false, failure: .cannotReopen, pagesChecked: 0, textSurvived: false, worstDivergence: 0)
        }
        guard let pdfKitDocument = PDFOpen.pdfKitDocument(at: output) else {
            return Report(passed: false, failure: .cannotReopen, pagesChecked: 0, textSurvived: false, worstDivergence: 0)
        }

        let pageCount = document.numberOfPages
        guard pageCount == expectedPageCount, pdfKitDocument.pageCount == expectedPageCount else {
            return Report(
                passed: false,
                failure: .pageCountMismatch(expected: expectedPageCount, got: pageCount),
                pagesChecked: 0,
                textSurvived: false,
                worstDivergence: 0
            )
        }

        let source = PDFOpen.document(at: original)
        let indices = sampleIndices(pageCount: pageCount)
        var worst = 0.0

        for index in indices {
            try checkpoint()

            let verdict = autoreleasepool { () -> (blank: Bool, divergence: Double?) in
                guard let page = document.page(at: index + 1),
                      let rendered = thumbnail(page: page) else { return (true, nil) }
                if isFlat(rendered) { return (true, nil) }

                // Compare against the same page of the input. A page that lost
                // an image still renders, still has text, and would sail past
                // every other check — this is the one that catches it.
                guard let sourcePage = source?.page(at: index + 1),
                      let reference = thumbnail(page: sourcePage) else { return (false, nil) }
                return (false, correlation(rendered, reference))
            }

            if verdict.blank {
                return Report(passed: false, failure: .blankPage(index: index),
                              pagesChecked: indices.count, textSurvived: false, worstDivergence: worst)
            }
            if let similarity = verdict.divergence {
                worst = max(worst, 1.0 - similarity)
                if similarity < minPageCorrelation {
                    return Report(
                        passed: false,
                        failure: .pageContentDiverged(index: index, difference: 1.0 - similarity),
                        pagesChecked: indices.count,
                        textSurvived: false,
                        worstDivergence: worst
                    )
                }
            }
        }

        var textSurvived = true
        if inputHadText {
            textSurvived = hasAnyText(pdfKitDocument, sampling: indices)
            if !textSurvived {
                return Report(passed: false, failure: .textDisappeared,
                              pagesChecked: indices.count, textSurvived: false, worstDivergence: worst)
            }
        }

        return Report(passed: true, failure: nil, pagesChecked: indices.count,
                      textSurvived: textSurvived, worstDivergence: worst)
    }

    /// Pearson correlation between two equally sized greyscale buffers.
    ///
    /// Returns 1 for "same picture, possibly lighter or darker" and collapses
    /// towards 0 when the structure itself changes. Two flat pages correlate
    /// perfectly by definition; the blank check has already handled those.
    static func correlation(_ a: [UInt8], _ b: [UInt8]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        let n = Double(a.count)

        var sumA = 0.0, sumB = 0.0
        for i in a.indices { sumA += Double(a[i]); sumB += Double(b[i]) }
        let meanA = sumA / n, meanB = sumB / n

        var covariance = 0.0, varianceA = 0.0, varianceB = 0.0
        for i in a.indices {
            let da = Double(a[i]) - meanA
            let db = Double(b[i]) - meanB
            covariance += da * db
            varianceA += da * da
            varianceB += db * db
        }

        // A page with no variation carries no structure to compare.
        let flatness = 1e-6 * n
        if varianceA <= flatness && varianceB <= flatness { return 1.0 }
        guard varianceA > 0, varianceB > 0 else { return 0.0 }

        return covariance / (varianceA.squareRoot() * varianceB.squareRoot())
    }

    static func sampleIndices(pageCount: Int) -> [Int] {
        guard pageCount > exhaustiveCheckLimit else { return Array(0..<pageCount) }
        var indices = Set<Int>([0, pageCount - 1])
        let step = Double(pageCount - 1) / Double(sampleCount - 1)
        for i in 0..<sampleCount {
            indices.insert(min(pageCount - 1, Int((Double(i) * step).rounded())))
        }
        return indices.sorted()
    }

    /// Renders a page into a small greyscale buffer, used both for the blank
    /// check and for comparing against the original.
    static func thumbnail(page: CGPDFPage) -> [UInt8]? {
        let box = InventoryBuilder.pageBox(page)
        guard box.width > 0, box.height > 0 else { return nil }

        let side = renderSide
        var buffer = [UInt8](repeating: 255, count: side * side)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }

            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            // High, not low. Low interpolation point-samples, and point-sampling
            // a noisy scan down to 64x64 picks essentially random pixels — two
            // renders of the same page then correlate at nearly zero. Averaging
            // is what makes this a structural comparison rather than a lottery.
            context.interpolationQuality = .high
            PageGeometry.draw(page: page, into: context, pixelWidth: side, pixelHeight: side)
            return true
        }
        return ok ? boxAverage(buffer, from: side, to: comparisonSide) : nil
    }

    /// Exact block averaging. `source` must be a square buffer whose side is a
    /// multiple of `target`.
    static func boxAverage(_ pixels: [UInt8], from source: Int, to target: Int) -> [UInt8] {
        let block = source / target
        guard block > 1 else { return pixels }

        var out = [UInt8](repeating: 0, count: target * target)
        let perBlock = block * block
        for y in 0..<target {
            for x in 0..<target {
                var total = 0
                for dy in 0..<block {
                    let row = (y * block + dy) * source + x * block
                    for dx in 0..<block { total += Int(pixels[row + dx]) }
                }
                out[y * target + x] = UInt8(total / perBlock)
            }
        }
        return out
    }

    /// A uniform field of one colour means we produced a blank sheet.
    static func isFlat(_ pixels: [UInt8]) -> Bool {
        guard let first = pixels.first else { return true }
        return !pixels.contains { $0 != first }
    }

    /// The input had text, so the output must still yield some. We sample the
    /// same pages we rendered rather than extracting the whole document.
    static func hasAnyText(_ document: PDFDocument, sampling indices: [Int]) -> Bool {
        for index in indices {
            guard let page = document.page(at: index) else { continue }
            if let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    /// Whether the *input* has extractable text, on the same sampled pages.
    /// Used so the comparison is like-for-like.
    static func inputHasText(url: URL, pageCount: Int) -> Bool {
        guard let document = PDFOpen.pdfKitDocument(at: url) else { return false }
        return hasAnyText(document, sampling: sampleIndices(pageCount: pageCount))
    }
}
