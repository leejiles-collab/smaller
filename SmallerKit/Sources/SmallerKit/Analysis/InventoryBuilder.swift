import Foundation
import CoreGraphics

/// Builds the one-and-only parse of a document. Everything downstream — the
/// strategy choice, the size estimate, the target-size solver's four passes —
/// reads this and never re-parses.
enum InventoryBuilder {

    enum BuildError: Error {
        case cannotOpen(URL)
        case noPages
    }

    /// A page is "scan-like" when a single image covers at least this much of it.
    static let scanCoverageThreshold = 0.85

    static func build(url: URL) throws -> PDFInventory {
        guard let document = CGPDFDocument(url as CFURL) else {
            throw BuildError.cannotOpen(url)
        }
        let pageCount = document.numberOfPages
        guard pageCount > 0 else { throw BuildError.noPages }

        let byteSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

        var pages: [PageSummary] = []
        var usages: [ImageUsage] = []
        pages.reserveCapacity(pageCount)

        for index in 0..<pageCount {
            autoreleasepool {
                guard let page = document.page(at: index + 1) else { return }

                let box = pageBox(page)
                let area = Double(box.width * box.height)

                let scanner = ContentScanner()
                scanner.scan(page: page)

                var pageImageBytes = 0
                var maxCoverage = 0.0

                for raw in scanner.images {
                    let usage = ImageUsage(
                        key: raw.key,
                        pageIndex: index,
                        pixelWidth: raw.pixelWidth,
                        pixelHeight: raw.pixelHeight,
                        bitsPerComponent: raw.bitsPerComponent,
                        componentCount: raw.colorSpace.componentCount,
                        colorSpaceName: raw.colorSpace.name,
                        filter: raw.filter,
                        rawByteLength: raw.encodedLength,
                        drawnWidthPoints: raw.drawnWidthPoints,
                        drawnHeightPoints: raw.drawnHeightPoints,
                        hasAlpha: raw.hasAlpha,
                        isStencilMask: raw.isStencilMask
                    )
                    usages.append(usage)
                    pageImageBytes += raw.encodedLength
                    maxCoverage = max(maxCoverage, usage.coverage(ofPageArea: area))
                }

                pages.append(PageSummary(
                    index: index,
                    widthPoints: Double(box.width),
                    heightPoints: Double(box.height),
                    rotation: Int(page.rotationAngle),
                    pageClass: classify(
                        imageCount: scanner.images.count,
                        maxCoverage: maxCoverage,
                        textOperators: scanner.textOperatorCount
                    ),
                    textOperatorCount: scanner.textOperatorCount,
                    imageCount: scanner.images.count,
                    imageBytes: pageImageBytes,
                    maxImageCoverage: maxCoverage
                ))
            }
        }

        // Images shared across pages are one cost in the file, not many.
        var seen = Set<ImageKey>()
        var uniqueImageBytes = 0
        for usage in usages where seen.insert(usage.key).inserted {
            uniqueImageBytes += usage.rawByteLength
        }

        let catalog = document.catalog
        let inventory = PDFInventory(
            url: url,
            byteSize: byteSize,
            pageCount: pageCount,
            pages: pages,
            images: usages,
            isEncrypted: document.isEncrypted,
            hasFormFields: hasFormFields(catalog: catalog),
            hasEmbeddedText: pages.contains { $0.textOperatorCount > 0 },
            imageBytes: min(uniqueImageBytes, byteSize),
            estimatedSizes: [:]
        )

        // Estimates need the finished inventory, so they land in a second pass.
        return PDFInventory(
            url: inventory.url,
            byteSize: inventory.byteSize,
            pageCount: inventory.pageCount,
            pages: inventory.pages,
            images: inventory.images,
            isEncrypted: inventory.isEncrypted,
            hasFormFields: inventory.hasFormFields,
            hasEmbeddedText: inventory.hasEmbeddedText,
            imageBytes: inventory.imageBytes,
            estimatedSizes: SizeEstimator.estimates(inventory: inventory)
        )
    }

    /// `scanLike` deliberately requires *zero* text operators, not "few".
    ///
    /// The spec said "little or no text", but scanned documents very often carry
    /// an invisible OCR layer, and rasterizing one silently destroys the ability
    /// to search or select the text. Those pages are classified `mixed` instead
    /// and get image substitution, which saves the same bytes and keeps the text.
    static func classify(imageCount: Int, maxCoverage: Double, textOperators: Int) -> PageClass {
        if imageCount == 0 { return .vectorOnly }
        if maxCoverage >= scanCoverageThreshold && textOperators == 0 { return .scanLike }
        return .mixed
    }

    static func pageBox(_ page: CGPDFPage) -> CGRect {
        let crop = page.getBoxRect(.cropBox)
        if !crop.isNull && !crop.isEmpty { return crop }
        return page.getBoxRect(.mediaBox)
    }

    static func hasFormFields(catalog: CGPDFDictionaryRef?) -> Bool {
        guard let catalog else { return false }
        var acroForm: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &acroForm), let acroForm else { return false }
        var fields: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(acroForm, "Fields", &fields), let fields else { return false }
        return CGPDFArrayGetCount(fields) > 0
    }
}
