import Foundation
import CoreGraphics
import CryptoKit

/// Rewrites a PDF with its images re-encoded, leaving everything else — text,
/// embedded fonts, vector art, links, outline — byte-identical.
///
/// ## Why not "replay the content stream"
///
/// The original plan was to replay each page's content stream into a
/// `CGContext(consumer:)` PDF context and intercept image draws. CoreGraphics
/// has no such interception point: `CGContextDrawPDFPage` is opaque, and doing
/// it by hand means writing a complete PDF interpreter — including re-emitting
/// text with the document's own embedded, subsetted, CID-keyed fonts, which
/// CoreGraphics gives no way to re-embed. Any such replay silently loses fonts.
///
/// So we work one level lower instead. The document's object graph is copied
/// out through `CGPDF*` and serialized back, and only the image XObject streams
/// are swapped for smaller ones. Content streams are copied verbatim, so text
/// stays exactly as sharp as it started — which is a stronger guarantee than
/// replay would have given.
final class PDFRebuilder {

    struct Stats {
        var imagesRecoded = 0
        var masksRecoded = 0
        var bytesBeforeRecode = 0
        var bytesAfterRecode = 0
        /// Distinct images we refused to re-encode.
        var imagesDeclined = 0
        var declinedBytes = 0
        /// Repeat placements of an image we had already written.
        var imagesDeduplicated = 0
        var imageDedupBytes = 0
        /// Non-image streams collapsed by content: embedded fonts, content
        /// streams, and any image we declined to recode.
        var streamsDeduplicated = 0
        var streamDedupBytes = 0
        var pagesRasterized = 0
        var rasterFallbacks: [(page: Int, reason: String)] = []
        var rasterizedPagesWithAnnotations = 0
        /// One verdict per distinct image, so the decline list is inspectable.
        var decisions: [ImageIdentity: ImageDecision] = [:]

        /// Bytes recovered purely by storing repeated content once.
        var dedupBytes: Int { imageDedupBytes + streamDedupBytes }
        /// Bytes recovered by re-encoding.
        var recodeBytes: Int { max(0, bytesBeforeRecode - bytesAfterRecode) }
    }

    enum RebuildError: Error {
        case streamUnreadable(String)
        case missingCatalog
        case missingPage(Int)
        case tooDeep
    }

    private let document: CGPDFDocument
    private let inventory: PDFInventory
    private let profile: CompressionProfile
    private let writer: PDFWriter
    private let uniqueImages: [ImageIdentity: ImageUsage]
    private let scanLikePages: Set<Int>

    /// Content fingerprint to object number, for every stream written so far.
    /// This is where duplicate embeds collapse.
    private var streamsByContent: [String: Int] = [:]
    /// Distinct image content to the object number of its recoded form.
    private var recodedImages: [ImageIdentity: Int] = [:]
    /// Streams currently being copied, with a number only if re-entered.
    private var inProgressStreams: [UInt: Int?] = [:]

    /// CoreGraphics hands back the same pointer for the same indirect object
    /// within one document handle (verified), so pointer identity both
    /// de-duplicates shared resources and breaks the `/Parent` and outline
    /// cycles: an object is registered here *before* its contents are walked.
    private var objectNumbers: [UInt: Int] = [:]
    private var stats = Stats()
    private var depth = 0

    private static let maxDepth = 64

    init(document: CGPDFDocument, inventory: PDFInventory, profile: CompressionProfile, outputURL: URL) throws {
        self.document = document
        self.inventory = inventory
        self.profile = profile
        self.writer = try PDFWriter(url: outputURL)
        self.uniqueImages = inventory.uniqueImages
        self.scanLikePages = Set(
            inventory.pages.filter { $0.pageClass == .scanLike }.map(\.index)
        )
    }

    // MARK: - Entry point

    /// - Parameter checkpoint: called once per page; throw from it to cancel.
    func run(
        progress: (Double) -> Void,
        checkpoint: () throws -> Void
    ) throws -> Stats {
        guard let catalog = document.catalog else { throw RebuildError.missingCatalog }

        let pageCount = document.numberOfPages
        let catalogNumber = writer.allocate()
        let pagesNumber = writer.allocate()
        let pageNumbers = (0..<pageCount).map { _ in writer.allocate() }

        // Registering the page objects up front is what makes internal links,
        // outline destinations and annotation back-references land on the right
        // object instead of duplicating whole pages.
        for index in 0..<pageCount {
            guard let page = document.page(at: index + 1), let dict = page.dictionary else {
                throw RebuildError.missingPage(index)
            }
            objectNumbers[Self.identity(dict)] = pageNumbers[index]
        }
        objectNumbers[Self.identity(catalog)] = catalogNumber
        if let pagesNode = Self.pagesNode(catalog) {
            objectNumbers[Self.identity(pagesNode)] = pagesNumber
        }

        for index in 0..<pageCount {
            try checkpoint()
            try autoreleasepool {
                guard let page = document.page(at: index + 1), let dict = page.dictionary else {
                    throw RebuildError.missingPage(index)
                }
                let body = try buildPage(page: page, dict: dict, index: index, parent: pagesNumber)
                try writer.write(object: pageNumbers[index], value: .dictionary(body))
            }
            progress(Double(index + 1) / Double(pageCount))
        }

        try writer.write(object: pagesNumber, value: .dictionary([
            "Type": .name("Pages"),
            "Kids": .array(pageNumbers.map { .reference($0) }),
            "Count": .integer(pageCount)
        ]))

        let catalogBody = try buildCatalog(catalog, pagesNumber: pagesNumber)
        try writer.write(object: catalogNumber, value: .dictionary(catalogBody))

        let infoNumber = writer.allocate()
        try writer.write(object: infoNumber, value: .dictionary([
            "Producer": .string(Array("Smaller".utf8))
        ]))

        try writer.finish(root: catalogNumber, info: infoNumber, documentID: documentID())
        return stats
    }

    func abandon() {
        writer.abandon()
    }

    // MARK: - Catalog

    private static let catalogKeys: Set<String> = [
        "Outlines", "PageLabels", "Names", "AcroForm", "ViewerPreferences",
        "PageLayout", "PageMode", "Lang", "OpenAction", "Dests", "MarkInfo"
    ]

    private func buildCatalog(_ catalog: CGPDFDictionaryRef, pagesNumber: Int) throws -> [String: PDFValue] {
        var out: [String: PDFValue] = [
            "Type": .name("Catalog"),
            "Pages": .reference(pagesNumber)
        ]
        for key in Self.catalogKeys {
            var object: CGPDFObjectRef?
            guard CGPDFDictionaryGetObject(catalog, key, &object), let object else { continue }
            if key == "Names" {
                // Everything except the file attachments, which we drop.
                var names: CGPDFDictionaryRef?
                if CGPDFObjectGetValue(object, .dictionary, &names), let names {
                    let copied = try copyDictionary(names, dropping: ["EmbeddedFiles"])
                    if !copied.isEmpty { out["Names"] = .dictionary(copied) }
                    continue
                }
            }
            out[key] = try copy(object: object)
        }
        return out
    }

    private static func pagesNode(_ catalog: CGPDFDictionaryRef) -> CGPDFDictionaryRef? {
        var pages: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(catalog, "Pages", &pages)
        return pages
    }

    // MARK: - Pages

    /// Keys copied onto a rebuilt page. An allowlist, because a stray
    /// `/StructParents` pointing into a structure tree we did not copy is worse
    /// than a missing one.
    private static let pageKeys: [String] = [
        "Contents", "Resources", "MediaBox", "CropBox", "BleedBox", "TrimBox",
        "ArtBox", "Rotate", "Group", "UserUnit", "Tabs"
    ]

    /// Annotation types that carry payloads we deliberately drop.
    private static let droppedAnnotationSubtypes: Set<String> = [
        "FileAttachment", "Sound", "Movie", "RichMedia", "Screen", "3D"
    ]

    private func buildPage(page: CGPDFPage, dict: CGPDFDictionaryRef, index: Int, parent: Int) throws -> [String: PDFValue] {
        // Rasterizing is a re-encode, so `.lossless` must not do it.
        if profile.recodesImages, scanLikePages.contains(index) {
            if let raster = try buildRasterizedPage(page: page, dict: dict, index: index, parent: parent) {
                return raster
            }
            stats.rasterFallbacks.append((page: index, reason: "render or encode failed"))
        }

        var out: [String: PDFValue] = [
            "Type": .name("Page"),
            "Parent": .reference(parent)
        ]

        for key in Self.pageKeys {
            // `/Resources`, `/MediaBox` and `/Rotate` may live on an ancestor
            // node; a rebuilt page has no ancestor to inherit from, so resolve
            // them here and write them down explicitly.
            guard let object = inheritedObject(dict, key: key) else { continue }
            out[key] = try copy(object: object)
        }

        if let annots = try copyAnnotations(dict) {
            out["Annots"] = annots
        }
        return out
    }

    private func copyAnnotations(_ pageDict: CGPDFDictionaryRef) throws -> PDFValue? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(pageDict, "Annots", &array), let array else { return nil }

        var kept: [PDFValue] = []
        for i in 0..<CGPDFArrayGetCount(array) {
            var annot: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(array, i, &annot), let annot else { continue }
            var subtypePtr: UnsafePointer<CChar>?
            CGPDFDictionaryGetName(annot, "Subtype", &subtypePtr)
            let subtype = subtypePtr.map { String(cString: $0) } ?? ""
            guard !Self.droppedAnnotationSubtypes.contains(subtype) else { continue }
            kept.append(try copyDictionaryAsIndirect(annot))
        }
        return kept.isEmpty ? nil : .array(kept)
    }

    /// Walks `/Parent` looking for an inheritable attribute.
    private func inheritedObject(_ dict: CGPDFDictionaryRef, key: String) -> CGPDFObjectRef? {
        var current: CGPDFDictionaryRef? = dict
        var hops = 0
        while let node = current, hops < Self.maxDepth {
            var object: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(node, key, &object), let object { return object }
            var parent: CGPDFDictionaryRef?
            current = CGPDFDictionaryGetDictionary(node, "Parent", &parent) ? parent : nil
            hops += 1
        }
        return nil
    }

    // MARK: - Strategy B: rasterize a scan-like page

    /// Only ever called for pages with a full-bleed image and *zero* text
    /// operators, so there is no text to destroy and nothing to extract later.
    private func buildRasterizedPage(page: CGPDFPage, dict: CGPDFDictionaryRef, index: Int, parent: Int) throws -> [String: PDFValue]? {
        let box = InventoryBuilder.pageBox(page)
        guard box.width > 1, box.height > 1 else { return nil }

        let display = PageGeometry.displaySize(box: box, rotation: Int(page.rotationAngle))
        let pointWidth = display.width
        let pointHeight = display.height

        let scale = profile.targetDPI / 72.0
        let pixelWidth = max(1, Int((pointWidth * scale).rounded()))
        let pixelHeight = max(1, Int((pointHeight * scale).rounded()))

        // A page big enough to blow the extension's memory budget is not worth
        // rasterizing; the per-image path handles it with far less resident data.
        guard pixelWidth * pixelHeight <= 40_000_000 else { return nil }

        let grayscale = profile.allowsGrayscaleForScans
        guard let context = ImageRecoder.bitmapContext(
            width: pixelWidth, height: pixelHeight, grayscale: grayscale
        ) else { return nil }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.interpolationQuality = .high

        PageGeometry.draw(page: page, into: context, pixelWidth: pixelWidth, pixelHeight: pixelHeight)

        guard let image = context.makeImage(),
              let jpeg = ImageRecoder.encodeJPEG(image, quality: profile.jpegQuality) else { return nil }

        var annots: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dict, "Annots", &annots), let annots, CGPDFArrayGetCount(annots) > 0 {
            stats.rasterizedPagesWithAnnotations += 1
        }

        let imageNumber = writer.allocate()
        try writer.write(object: imageNumber, streamDictionary: [
            "Type": .name("XObject"),
            "Subtype": .name("Image"),
            "Width": .integer(pixelWidth),
            "Height": .integer(pixelHeight),
            "ColorSpace": .name(grayscale ? "DeviceGray" : "DeviceRGB"),
            "BitsPerComponent": .integer(8),
            "Filter": .name("DCTDecode")
        ], data: jpeg)

        let contentText = "q \(PDFValue.format(Double(pointWidth))) 0 0 \(PDFValue.format(Double(pointHeight))) 0 0 cm /X0 Do Q\n"
        let contentNumber = writer.allocate()
        try writeStream(number: contentNumber, dictionary: [:], data: Data(contentText.utf8))

        stats.pagesRasterized += 1

        return [
            "Type": .name("Page"),
            "Parent": .reference(parent),
            "MediaBox": .array([.integer(0), .integer(0), .real(Double(pointWidth)), .real(Double(pointHeight))]),
            "Rotate": .integer(0),
            "Resources": .dictionary([
                "ProcSet": .array([.name("PDF"), .name("ImageC")]),
                "XObject": .dictionary(["X0": .reference(imageNumber)])
            ]),
            "Contents": .reference(contentNumber)
        ]
    }

    // MARK: - Generic object copying

    private func copy(object: CGPDFObjectRef) throws -> PDFValue {
        guard depth < Self.maxDepth else { throw RebuildError.tooDeep }

        switch CGPDFObjectGetType(object) {
        case .null:
            return .null

        case .boolean:
            var value: CGPDFBoolean = 0
            CGPDFObjectGetValue(object, .boolean, &value)
            return .bool(value != 0)

        case .integer:
            var value: CGPDFInteger = 0
            CGPDFObjectGetValue(object, .integer, &value)
            return .integer(Int(value))

        case .real:
            var value: CGPDFReal = 0
            CGPDFObjectGetValue(object, .real, &value)
            return .real(Double(value))

        case .name:
            var value: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .name, &value), let value else { return .null }
            return .name(String(cString: value))

        case .string:
            var value: CGPDFStringRef?
            guard CGPDFObjectGetValue(object, .string, &value), let value,
                  let bytes = CGPDFStringGetBytePtr(value) else { return .string([]) }
            let length = CGPDFStringGetLength(value)
            return .string(Array(UnsafeBufferPointer(start: bytes, count: length)))

        case .array:
            var value: CGPDFArrayRef?
            guard CGPDFObjectGetValue(object, .array, &value), let value else { return .null }
            depth += 1
            defer { depth -= 1 }
            var items: [PDFValue] = []
            items.reserveCapacity(CGPDFArrayGetCount(value))
            for i in 0..<CGPDFArrayGetCount(value) {
                var element: CGPDFObjectRef?
                guard CGPDFArrayGetObject(value, i, &element), let element else {
                    items.append(.null)
                    continue
                }
                items.append(try copy(object: element))
            }
            return .array(items)

        case .dictionary:
            var value: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &value), let value else { return .null }
            return try copyDictionaryAsIndirect(value)

        case .stream:
            var value: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &value), let value else { return .null }
            return try copyStreamAsIndirect(value)

        @unknown default:
            return .null
        }
    }

    /// Every dictionary becomes an indirect object. Slightly more objects than
    /// strictly necessary, and the price is worth paying: reserving the number
    /// before recursing is what makes a cyclic graph terminate.
    private func copyDictionaryAsIndirect(_ dict: CGPDFDictionaryRef) throws -> PDFValue {
        let id = Self.identity(dict)
        if let existing = objectNumbers[id] { return .reference(existing) }

        let number = writer.allocate()
        objectNumbers[id] = number

        depth += 1
        let body: [String: PDFValue]
        do {
            body = try copyDictionary(dict, dropping: [])
        } catch {
            depth -= 1
            throw error
        }
        depth -= 1

        try writer.write(object: number, value: .dictionary(body))
        return .reference(number)
    }

    /// Keys dropped from every dictionary we copy.
    private static let globallyDroppedKeys: Set<String> = [
        "Metadata",   // XMP packet; pure overhead for us
        "Thumb",      // embedded page thumbnails
        "PieceInfo",  // private application data
        "StructParents", "StructTreeRoot"
    ]

    private func copyDictionary(_ dict: CGPDFDictionaryRef, dropping extra: Set<String>) throws -> [String: PDFValue] {
        var keys: [String] = []
        withUnsafeMutablePointer(to: &keys) { pointer in
            CGPDFDictionaryApplyBlock(dict, { key, _, info in
                info!.assumingMemoryBound(to: [String].self).pointee.append(String(cString: key))
                return true
            }, pointer)
        }

        var out: [String: PDFValue] = [:]
        for key in keys {
            guard !Self.globallyDroppedKeys.contains(key), !extra.contains(key) else { continue }
            var object: CGPDFObjectRef?
            guard CGPDFDictionaryGetObject(dict, key, &object), let object else { continue }
            out[key] = try copy(object: object)
        }
        return out
    }

    // MARK: - Streams

    /// Copies a stream, de-duplicating by content.
    ///
    /// Object numbers are *not* reserved up front here, unlike dictionaries:
    /// we need the finished bytes before we know whether this stream is one we
    /// have already written. Streams that turn out to be re-entrant (a form
    /// whose resources reach back to itself) get a number assigned on re-entry
    /// and skip de-duplication, which is the only correct thing to do.
    private func copyStreamAsIndirect(_ stream: CGPDFStreamRef) throws -> PDFValue {
        let id = Self.identity(stream)
        if let existing = objectNumbers[id] { return .reference(existing) }

        if let existingEntry = inProgressStreams[id] {
            let number = existingEntry ?? writer.allocate()
            inProgressStreams[id] = number
            return .reference(number)
        }
        inProgressStreams[id] = nil
        defer { inProgressStreams.removeValue(forKey: id) }

        guard let dict = CGPDFStreamGetDictionary(stream) else {
            let number = writer.allocate()
            objectNumbers[id] = number
            try writer.write(object: number, value: .null)
            return .reference(number)
        }

        if let substituted = try substituteImage(stream: stream, dict: dict, id: id) {
            return substituted
        }

        depth += 1
        let (dictionary, data) = try readStream(stream, dict: dict)
        depth -= 1

        let reentrantNumber = inProgressStreams[id] ?? nil
        let fingerprint = Self.streamFingerprint(dictionary: dictionary, data: data)

        // The cheapest win in the whole engine: an identical stream — a repeated
        // image, a repeated embedded font program — is written once.
        if reentrantNumber == nil, let canonical = streamsByContent[fingerprint] {
            objectNumbers[id] = canonical
            stats.streamsDeduplicated += 1
            stats.streamDedupBytes += Self.encodedLength(of: dict)
            return .reference(canonical)
        }

        let number = reentrantNumber ?? writer.allocate()
        objectNumbers[id] = number
        if reentrantNumber == nil { streamsByContent[fingerprint] = number }
        try writeStream(number: number, dictionary: dictionary, data: data)
        return .reference(number)
    }

    /// `/Length` is the stream's encoded size — what it actually costs in the
    /// file, as opposed to the size of its decoded contents.
    private static func encodedLength(of dict: CGPDFDictionaryRef) -> Int {
        var length: CGPDFInteger = 0
        CGPDFDictionaryGetInteger(dict, "Length", &length)
        return Int(length)
    }

    /// Identity of a finished stream: its serialized dictionary plus its bytes.
    ///
    /// Taking the *copied* dictionary rather than the source one matters — by
    /// this point any sub-objects it references have themselves been
    /// de-duplicated, so two genuinely identical streams serialize identically.
    private static func streamFingerprint(dictionary: [String: PDFValue], data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(PDFValue.dictionary(dictionary).serialized))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Copies a stream's bytes and works out which filters are still applied.
    ///
    /// `CGPDFStreamCopyData` transparently undoes the byte-level filters
    /// (Flate, LZW, ASCII85, RunLength) and reports via `CGPDFDataFormat`
    /// whether what remains is JPEG or JPEG 2000. There is no API for the
    /// untouched bytes — `CGPDFStreamCopyRawData` does not exist — so the
    /// residual filter chain has to be reconstructed from those two facts.
    private func readStream(_ stream: CGPDFStreamRef, dict: CGPDFDictionaryRef) throws -> ([String: PDFValue], Data) {
        var format = CGPDFDataFormat.raw
        guard let cfData = CGPDFStreamCopyData(stream, &format) else {
            throw RebuildError.streamUnreadable("CGPDFStreamCopyData returned nil")
        }
        let data = cfData as Data

        var out = try copyDictionary(dict, dropping: ["Filter", "DecodeParms", "DP", "Length", "F"])

        let filters = FilterChain.names(from: dict)
        let residualIndex = filters.lastIndex { !FilterChain.standard.contains($0) }

        if let residualIndex {
            out["Filter"] = .name(filters[residualIndex])
            if let parms = decodeParms(dict, filterCount: filters.count, index: residualIndex) {
                out["DecodeParms"] = try copy(object: parms)
            }
            return (out, data)
        }

        // Nothing image-specific left: the bytes are plain, so we re-deflate.
        if let deflated = Flate.encode(data) {
            out["Filter"] = .name("FlateDecode")
            return (out, deflated)
        }
        return (out, data)
    }

    private func decodeParms(_ dict: CGPDFDictionaryRef, filterCount: Int, index: Int) -> CGPDFObjectRef? {
        for key in ["DecodeParms", "DP"] {
            var object: CGPDFObjectRef?
            guard CGPDFDictionaryGetObject(dict, key, &object), let object else { continue }
            var array: CGPDFArrayRef?
            if CGPDFObjectGetValue(object, .array, &array), let array {
                var element: CGPDFObjectRef?
                if index < CGPDFArrayGetCount(array), CGPDFArrayGetObject(array, index, &element) {
                    return element
                }
                return nil
            }
            // A bare dictionary only makes sense when there is one filter.
            return filterCount <= 1 ? object : nil
        }
        return nil
    }

    private func writeStream(number: Int, dictionary: [String: PDFValue], data: Data) throws {
        var dict = dictionary
        if dict["Filter"] == nil, let deflated = Flate.encode(data) {
            dict["Filter"] = .name("FlateDecode")
            try writer.write(object: number, streamDictionary: dict, data: deflated)
            return
        }
        try writer.write(object: number, streamDictionary: dict, data: data)
    }

    // MARK: - Image substitution

    /// The one place the file actually gets smaller.
    ///
    /// Returns nil when the image should fall through to the ordinary stream
    /// path, which still de-duplicates it — declining to *recode* an image is
    /// not the same as declining to stop storing it twenty-eight times.
    private func substituteImage(stream: CGPDFStreamRef, dict: CGPDFDictionaryRef, id: UInt) throws -> PDFValue? {
        guard profile.recodesImages else { return nil }

        var subtypePtr: UnsafePointer<CChar>?
        CGPDFDictionaryGetName(dict, "Subtype", &subtypePtr)
        guard subtypePtr.map({ String(cString: $0) }) == "Image" else { return nil }

        guard let (data, format) = ImageFingerprint.read(stream: stream) else {
            throw RebuildError.streamUnreadable("image stream could not be read")
        }

        let identity = ImageFingerprint.identity(
            data: data,
            descriptor: ImageFingerprint.descriptor(dict: dict),
            maskDigest: ImageFingerprint.maskDigest(imageDict: dict)
        )

        // Already recoded this exact picture. Point at it and move on: this is
        // what stops a 28-slide deck decoding its banner 28 times.
        if let canonical = recodedImages[identity] {
            objectNumbers[id] = canonical
            note(identity, .deduplicated)
            stats.imagesDeduplicated += 1
            // What this duplicate cost *in the file*, which is its encoded
            // length — not the size of the pixels we just decoded.
            stats.imageDedupBytes += Self.encodedLength(of: dict)
            return .reference(canonical)
        }

        // No inventory entry means we never saw it drawn, so we do not know what
        // resolution it needs. Leave it alone rather than guess.
        guard let usage = uniqueImages[identity] else {
            note(identity, .declined(.neverDrawn))
            return nil
        }

        if let reason = usage.declineReason {
            note(identity, .declined(reason))
            stats.imagesDeclined += 1
            stats.declinedBytes += usage.totalByteLength
            return nil
        }

        let grayscale = profile.allowsGrayscaleForScans && scanLikePages.contains(usage.pageIndex)
        let outcome = ImageRecoder.recode(
            stream: stream,
            dict: dict,
            sourceData: data,
            sourceFormat: format,
            usage: usage,
            profile: profile,
            grayscale: grayscale
        )

        let recoded: ImageRecoder.Recoded
        switch outcome {
        case .success(let value):
            recoded = value
        case .failure(let failure):
            switch failure {
            case .notSmaller:
                note(identity, .noSmaller)
            case .decodeFailed:
                note(identity, .declined(.decodeFailed))
                stats.imagesDeclined += 1
                stats.declinedBytes += usage.totalByteLength
            case .maskUndecodable:
                note(identity, .declined(.maskUndecodable))
                stats.imagesDeclined += 1
                stats.declinedBytes += usage.totalByteLength
            }
            return nil
        }

        var body: [String: PDFValue] = [
            "Type": .name("XObject"),
            "Subtype": .name("Image"),
            "Width": .integer(recoded.pixelWidth),
            "Height": .integer(recoded.pixelHeight),
            "ColorSpace": .name(recoded.isGrayscale ? "DeviceGray" : "DeviceRGB"),
            "BitsPerComponent": .integer(8),
            "Filter": .name("DCTDecode")
        ]

        var produced = recoded.jpegData.count

        if let mask = recoded.mask {
            var maskBody: [String: PDFValue] = [
                "Type": .name("XObject"),
                "Subtype": .name("Image"),
                "Width": .integer(mask.pixelWidth),
                "Height": .integer(mask.pixelHeight),
                "ColorSpace": .name("DeviceGray"),
                "BitsPerComponent": .integer(8)
            ]
            if mask.isFlate { maskBody["Filter"] = .name("FlateDecode") }

            let maskNumber = writer.allocate()
            try writer.write(object: maskNumber, streamDictionary: maskBody, data: mask.data)
            body["SMask"] = .reference(maskNumber)
            produced += mask.data.count
            stats.masksRecoded += 1
        }

        let number = writer.allocate()
        objectNumbers[id] = number
        recodedImages[identity] = number
        try writer.write(object: number, streamDictionary: body, data: recoded.jpegData)

        note(identity, recoded.mask == nil ? .recoded : .recodedWithMask)
        stats.imagesRecoded += 1
        stats.bytesBeforeRecode += usage.totalByteLength
        stats.bytesAfterRecode += produced
        return .reference(number)
    }

    /// Records the decision for a distinct image, once.
    private func note(_ identity: ImageIdentity, _ decision: ImageDecision) {
        if case .deduplicated = decision {
            return  // the canonical copy already carries the interesting verdict
        }
        stats.decisions[identity] = decision
    }

    // MARK: - Helpers

    /// CoreGraphics spells `CGPDFDictionaryRef` and `CGPDFStreamRef` as
    /// different opaque pointer types; all we want is the address.
    private static func identity<Pointer>(_ pointer: Pointer) -> UInt {
        UInt(bitPattern: unsafeBitCast(pointer, to: Int.self))
    }

    private func documentID() -> [UInt8] {
        var hash = FNV1a.hash(Array(inventory.url.path.utf8))
        hash = hash &+ UInt64(inventory.byteSize) &* 0x9E37_79B9_7F4A_7C15
        var bytes: [UInt8] = []
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((hash >> UInt64(shift)) & 0xFF))
        }
        return bytes + bytes
    }
}
