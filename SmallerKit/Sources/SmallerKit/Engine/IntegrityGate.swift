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

    struct Report {
        let passed: Bool
        let failure: IntegrityFailure?
        let pagesChecked: Int
        let textSurvived: Bool
    }

    static func check(
        output: URL,
        expectedPageCount: Int,
        inputHadText: Bool,
        checkpoint: () throws -> Void
    ) throws -> Report {
        guard let document = CGPDFDocument(output as CFURL) else {
            return Report(passed: false, failure: .cannotReopen, pagesChecked: 0, textSurvived: false)
        }
        guard let pdfKitDocument = PDFDocument(url: output) else {
            return Report(passed: false, failure: .cannotReopen, pagesChecked: 0, textSurvived: false)
        }

        let pageCount = document.numberOfPages
        guard pageCount == expectedPageCount, pdfKitDocument.pageCount == expectedPageCount else {
            return Report(
                passed: false,
                failure: .pageCountMismatch(expected: expectedPageCount, got: pageCount),
                pagesChecked: 0,
                textSurvived: false
            )
        }

        let indices = sampleIndices(pageCount: pageCount)
        for index in indices {
            try checkpoint()
            let blank = try autoreleasepool { () -> Bool in
                guard let page = document.page(at: index + 1) else { return true }
                return isBlank(page: page)
            }
            if blank {
                return Report(passed: false, failure: .blankPage(index: index), pagesChecked: indices.count, textSurvived: false)
            }
        }

        var textSurvived = true
        if inputHadText {
            textSurvived = hasAnyText(pdfKitDocument, sampling: indices)
            if !textSurvived {
                return Report(passed: false, failure: .textDisappeared, pagesChecked: indices.count, textSurvived: false)
            }
        }

        return Report(passed: true, failure: nil, pagesChecked: indices.count, textSurvived: textSurvived)
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

    /// Renders the page small and asks whether anything at all was drawn.
    /// A uniform field of one colour means we produced a blank sheet.
    static func isBlank(page: CGPDFPage) -> Bool {
        let box = InventoryBuilder.pageBox(page)
        guard box.width > 0, box.height > 0 else { return true }

        let side = 48
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return false }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .low
        let destination = CGRect(x: 0, y: 0, width: side, height: side)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: destination, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)

        guard let data = context.data else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side)
        let first = pixels[0]
        for i in 1..<(side * side) where pixels[i] != first {
            return false
        }
        return true
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
        guard let document = PDFDocument(url: url) else { return false }
        return hasAnyText(document, sampling: sampleIndices(pageCount: pageCount))
    }
}
