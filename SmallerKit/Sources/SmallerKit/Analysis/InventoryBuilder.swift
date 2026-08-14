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

        // Survey first, walking page structure only — no image bytes are read,
        // so this costs almost nothing. Its whole job is to find which image
        // keys occur on more than one object, because those are the only images
        // that could have a duplicate and so the only ones worth hashing.
        let survey = scan(document: document, pageCount: pageCount, identities: ContentScanner.IdentityCache())
        let contested = contestedKeys(in: survey)

        // Now hash, but only the contested ones. When nothing is contested there
        // is nothing a second pass could learn, so the survey stands as the scan.
        let scanned = contested.isEmpty
            ? survey
            : scan(
                document: document,
                pageCount: pageCount,
                identities: ContentScanner.IdentityCache(contestedKeys: contested)
            )

        let pages = scanned.pages
        let usages = scanned.usages
        let objectBytes = scanned.objectBytes
        let maskObjectAddresses = scanned.maskObjectAddresses
        return try assemble(
            url: url,
            document: document,
            pageCount: pageCount,
            byteSize: byteSize,
            pages: pages,
            usages: usages,
            objectBytes: objectBytes,
            maskObjectAddresses: maskObjectAddresses,
            contentHashedKeys: contested
        )
    }

    // MARK: - Scanning

    /// One walk over every page. Identity policy lives in `identities`, so the
    /// same walk serves both the cheap survey and the hashing pass.
    private struct Scan {
        var pages: [PageSummary] = []
        var usages: [ImageUsage] = []
        /// Distinct stream objects, so a banner embedded 28 times as 28 separate
        /// objects is counted 28 times against the file — which is what it costs.
        var objectBytes: [UInt: Int] = [:]
        var maskObjectAddresses = Set<UInt>()
        /// Distinct objects carrying each key, which is what decides whether a
        /// key is contested. Placements do not count: one object drawn on 28
        /// slides is still one object and has nothing to be deduplicated against.
        var objectsByKey: [ImageKey: Set<UInt>] = [:]
    }

    private static func scan(
        document: CGPDFDocument,
        pageCount: Int,
        identities: ContentScanner.IdentityCache
    ) -> Scan {
        var result = Scan()
        result.pages.reserveCapacity(pageCount)

        for index in 0..<pageCount {
            autoreleasepool {
                guard let page = document.page(at: index + 1) else { return }

                let box = pageBox(page)
                let area = Double(box.width * box.height)

                let scanner = ContentScanner(identities: identities)
                scanner.scan(page: page)

                var pageImageBytes = 0
                var maxCoverage = 0.0

                for raw in scanner.images {
                    let usage = ImageUsage(
                        identity: raw.identity,
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
                        mask: raw.mask,
                        hasColourKeyMask: raw.hasColourKeyMask,
                        hasDecodeArray: raw.hasDecodeArray,
                        isStencilMask: raw.isStencilMask
                    )
                    result.usages.append(usage)
                    result.objectBytes[raw.objectAddress] = usage.totalByteLength
                    result.objectsByKey[raw.key, default: []].insert(raw.objectAddress)
                    if let maskAddress = raw.maskObjectAddress {
                        result.maskObjectAddresses.insert(maskAddress)
                    }
                    pageImageBytes += raw.encodedLength
                    maxCoverage = max(maxCoverage, usage.coverage(ofPageArea: area))
                }

                result.pages.append(PageSummary(
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
        return result
    }

    /// Keys carried by more than one distinct object. Only these can possibly
    /// have a byte-identical twin, so only these are worth reading pixels for.
    private static func contestedKeys(in scan: Scan) -> Set<ImageKey> {
        Set(scan.objectsByKey.filter { $0.value.count > 1 }.keys)
    }

    // MARK: - Assembly

    private static func assemble(
        url: URL,
        document: CGPDFDocument,
        pageCount: Int,
        byteSize: Int,
        pages: [PageSummary],
        usages: [ImageUsage],
        objectBytes: [UInt: Int],
        maskObjectAddresses: Set<UInt>,
        contentHashedKeys: Set<ImageKey>
    ) throws -> PDFInventory {
        // What the images cost in the file: one entry per distinct object, so
        // 28 separate copies of the same banner count 28 times.
        let imageObjectBytes = objectBytes.values.reduce(0, +)

        // What they would cost if each distinct picture were stored once.
        var seenContent = Set<ImageIdentity>()
        var uniqueImageBytes = 0
        for usage in usages where seenContent.insert(usage.identity).inserted {
            uniqueImageBytes += usage.totalByteLength
        }

        // What CoreGraphics can actually reach. Counted from the resource
        // dictionaries rather than from what was painted, because an image that
        // is present but never drawn is perfectly normal and must not look like
        // an object CoreGraphics failed to resolve.
        var reachable = RawCensus.reachableImageObjects(document: document)
        reachable.formUnion(objectBytes.keys)
        reachable.formUnion(maskObjectAddresses)

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
            xrefWasRepaired: xrefWasRepaired(url: url, document: document),
            rawImageObjectCount: RawCensus.imageObjectCount(url: url) ?? 0,
            resolvedImageObjectCount: reachable.count,
            imageObjectBytes: min(imageObjectBytes, byteSize),
            uniqueImageBytes: min(uniqueImageBytes, byteSize),
            contentHashedKeys: contentHashedKeys,
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
            xrefWasRepaired: inventory.xrefWasRepaired,
            rawImageObjectCount: inventory.rawImageObjectCount,
            resolvedImageObjectCount: inventory.resolvedImageObjectCount,
            imageObjectBytes: inventory.imageObjectBytes,
            uniqueImageBytes: inventory.uniqueImageBytes,
            contentHashedKeys: inventory.contentHashedKeys,
            estimatedSizes: SizeEstimator.estimates(inventory: inventory)
        )
    }

    /// Detects a file whose cross-reference table does not match its contents.
    ///
    /// This matters more than it sounds. When the table is wrong, CoreGraphics
    /// opens the file anyway but cannot resolve some indirect objects — and it
    /// never says which. Measured on a deliberately damaged 14-slide deck, it
    /// reported all 14 pages with their `/Contents` and `/Resources` intact
    /// while silently losing 24 of 28 image objects. Anything we rebuilt from
    /// that view would be missing content, so the file is flagged here and the
    /// output is checked against the input page by page before we ship it.
    ///
    /// The check reads the table and verifies each offset actually lands on the
    /// object header it claims. Cheap: a seek and a few bytes per entry.
    static func xrefWasRepaired(url: URL, document: CGPDFDocument) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        let size = FileSize.bytes(at: url)
        let tailLength = min(2048, size)
        guard tailLength > 0 else { return false }
        try? handle.seek(toOffset: UInt64(size - tailLength))
        guard let tail = try? handle.read(upToCount: tailLength),
              let text = String(data: tail, encoding: .isoLatin1),
              let range = text.range(of: "startxref", options: .backwards) else {
            return true
        }

        let digits = text[range.upperBound...]
            .drop { $0 == "\r" || $0 == "\n" || $0 == " " }
            .prefix { $0.isNumber }
        guard let offset = Int(digits), offset > 0, offset < size else { return true }

        try? handle.seek(toOffset: UInt64(offset))
        guard let head = try? handle.read(upToCount: 64),
              let marker = String(data: head, encoding: .isoLatin1) else { return true }

        // A cross-reference *stream* is compressed; we cannot cheaply audit it,
        // and its very presence means the producer was not hand-rolling offsets.
        if marker.range(of: #"^\d+\s+\d+\s+obj"#, options: .regularExpression) != nil { return false }
        guard marker.hasPrefix("xref") else { return true }

        return classicTableIsWrong(handle: handle, tableOffset: offset, fileSize: size)
    }

    /// Walks a classic `xref` table and checks the entries point where they say.
    private static func classicTableIsWrong(handle: FileHandle, tableOffset: Int, fileSize: Int) -> Bool {
        try? handle.seek(toOffset: UInt64(tableOffset))
        let windowLength = min(64 * 1024, fileSize - tableOffset)
        guard windowLength > 0,
              let window = try? handle.read(upToCount: windowLength),
              let text = String(data: window, encoding: .isoLatin1) else { return true }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.isEmpty, lines[0].hasPrefix("xref") else { return true }
        lines.removeFirst()

        var objectNumber = 0
        var checked = 0
        var wrong = 0

        for line in lines {
            if line.hasPrefix("trailer") { break }

            // Subsection header: "<first> <count>".
            let header = line.split(separator: " ")
            if header.count == 2, let first = Int(header[0]), Int(header[1]) != nil {
                objectNumber = first
                continue
            }

            // Entry: "<10-digit offset> <5-digit generation> <n|f>".
            let parts = line.split(separator: " ")
            guard parts.count >= 3, let entryOffset = Int(parts[0]) else { continue }
            defer { objectNumber += 1 }
            guard parts[2] == "n", entryOffset > 0, entryOffset < fileSize else { continue }

            // Only sample; a damaged table shows itself quickly.
            guard checked < 40 else { break }
            checked += 1

            try? handle.seek(toOffset: UInt64(entryOffset))
            guard let bytes = try? handle.read(upToCount: 24),
                  let head = String(data: bytes, encoding: .isoLatin1),
                  head.hasPrefix("\(objectNumber) ") , head.contains("obj") else {
                wrong += 1
                continue
            }
        }

        return checked > 0 && wrong > 0
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
