import Foundation
import CoreGraphics

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
        var bytesBeforeRecode = 0
        var bytesAfterRecode = 0
        var imagesSkipped = 0
        var skippedImageBytes = 0
        var pagesRasterized = 0
        var rasterFallbacks: [(page: Int, reason: String)] = []
        var rasterizedPagesWithAnnotations = 0
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
    private let uniqueImages: [ImageKey: ImageUsage]
    private let scanLikePages: Set<Int>

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
        if scanLikePages.contains(index) {
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

        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let rotated = rotation == 90 || rotation == 270
        let pointWidth = rotated ? box.height : box.width
        let pointHeight = rotated ? box.width : box.height

        let scale = profile.targetDPI / 72.0
        let pixelWidth = max(1, Int((pointWidth * scale).rounded()))
        let pixelHeight = max(1, Int((pointHeight * scale).rounded()))

        // A page big enough to blow the extension's memory budget is not worth
        // rasterizing; the per-image path handles it with far less resident data.
        guard pixelWidth * pixelHeight <= 40_000_000 else { return nil }

        let grayscale = profile.allowsGrayscaleForScans
        let space = grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = grayscale ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.interpolationQuality = .high

        let destination = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: destination, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)

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

    private func copyStreamAsIndirect(_ stream: CGPDFStreamRef) throws -> PDFValue {
        let id = Self.identity(stream)
        if let existing = objectNumbers[id] { return .reference(existing) }

        let number = writer.allocate()
        objectNumbers[id] = number

        guard let dict = CGPDFStreamGetDictionary(stream) else {
            try writer.write(object: number, value: .null)
            return .reference(number)
        }

        if let substituted = try substituteImage(stream: stream, dict: dict, number: number) {
            return substituted
        }

        depth += 1
        let (dictionary, data) = try readStream(stream, dict: dict)
        depth -= 1
        try writeStream(number: number, dictionary: dictionary, data: data)
        return .reference(number)
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
    private func substituteImage(stream: CGPDFStreamRef, dict: CGPDFDictionaryRef, number: Int) throws -> PDFValue? {
        var subtypePtr: UnsafePointer<CChar>?
        CGPDFDictionaryGetName(dict, "Subtype", &subtypePtr)
        guard subtypePtr.map({ String(cString: $0) }) == "Image" else { return nil }

        var width: CGPDFInteger = 0
        var height: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dict, "Width", &width),
              CGPDFDictionaryGetInteger(dict, "Height", &height) else { return nil }

        var bpc: CGPDFInteger = 8
        if !CGPDFDictionaryGetInteger(dict, "BitsPerComponent", &bpc) { bpc = 8 }
        var isMask = false
        CGPDFDictionaryGetBoolean(dict, "ImageMask", &isMask)
        if isMask { bpc = 1 }

        var length: CGPDFInteger = 0
        CGPDFDictionaryGetInteger(dict, "Length", &length)

        let key = ImageKey(
            pixelWidth: Int(width),
            pixelHeight: Int(height),
            bitsPerComponent: Int(bpc),
            encodedLength: Int(length),
            filter: FilterChain.imageFilter(FilterChain.names(from: dict)).rawValue
        )

        // No inventory entry means we never saw it drawn, so we do not know what
        // resolution it is presented at. Leave it alone rather than guess.
        guard let usage = uniqueImages[key] else { return nil }

        guard usage.isRecodable else {
            stats.imagesSkipped += 1
            stats.skippedImageBytes += usage.rawByteLength
            return nil
        }

        let grayscale = profile.allowsGrayscaleForScans && scanLikePages.contains(usage.pageIndex)
        guard let recoded = ImageRecoder.recode(
            stream: stream,
            usage: usage,
            profile: profile,
            grayscale: grayscale,
            originalLength: Int(length)
        ) else {
            stats.imagesSkipped += 1
            stats.skippedImageBytes += usage.rawByteLength
            return nil
        }

        stats.imagesRecoded += 1
        stats.bytesBeforeRecode += Int(length)
        stats.bytesAfterRecode += recoded.jpegData.count

        try writer.write(object: number, streamDictionary: [
            "Type": .name("XObject"),
            "Subtype": .name("Image"),
            "Width": .integer(recoded.pixelWidth),
            "Height": .integer(recoded.pixelHeight),
            "ColorSpace": .name(recoded.isGrayscale ? "DeviceGray" : "DeviceRGB"),
            "BitsPerComponent": .integer(8),
            "Filter": .name("DCTDecode")
        ], data: recoded.jpegData)

        return .reference(number)
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
