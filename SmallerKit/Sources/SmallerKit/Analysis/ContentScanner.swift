import Foundation
import CoreGraphics

/// Walks a page's content stream keeping the graphics state stack, so that when
/// an image is drawn we know the matrix it is drawn under — and therefore the
/// size it actually occupies on the page, which is the only way to know whether
/// its pixels are wasted.
///
/// This is the fiddly part of the whole engine. `Do` alone tells you an image
/// was painted; only the CTM tells you it was painted into a one-inch box.
final class ContentScanner {

    struct RawImage {
        let identity: ImageIdentity
        let key: ImageKey
        let pixelWidth: Int
        let pixelHeight: Int
        let bitsPerComponent: Int
        let colorSpace: ColorSpaceInfo
        let filter: ImageFilter
        let encodedLength: Int
        let mask: MaskInfo?
        let hasColourKeyMask: Bool
        let hasDecodeArray: Bool
        let isStencilMask: Bool
        /// Address of the stream object, so repeated placements of the same
        /// object are only counted once against the file's byte cost.
        let objectAddress: UInt
        /// Address of the mask's stream object, which is a separate image
        /// XObject in the file and must be counted as one.
        let maskObjectAddress: UInt?
        var drawnWidthPoints: Double
        var drawnHeightPoints: Double
    }

    /// Shared across every page of a document, so an image placed on 28 slides
    /// is hashed once rather than 28 times.
    final class IdentityCache {
        private var cache: [UInt: ImageIdentity] = [:]

        func identity(for address: UInt, stream: CGPDFStreamRef, dict: CGPDFDictionaryRef) -> ImageIdentity? {
            if let cached = cache[address] { return cached }
            guard let computed = ImageFingerprint.compute(stream: stream, dict: dict) else { return nil }
            cache[address] = computed
            return computed
        }
    }

    // Collected results
    private(set) var images: [RawImage] = []
    private(set) var textOperatorCount = 0
    private(set) var inlineImageCount = 0

    private let identities: IdentityCache

    init(identities: IdentityCache) {
        self.identities = identities
    }

    // Graphics state
    fileprivate var ctm: CGAffineTransform = .identity
    fileprivate var stack: [CGAffineTransform] = []
    fileprivate var depth = 0
    fileprivate var formsInProgress: Set<UInt> = []

    private static let maxFormDepth = 12

    /// Resources of the page currently being scanned. Form XObjects are allowed
    /// to omit `/Resources` and inherit these, and `CGPDFContentStreamCreateWithStream`
    /// insists on being handed a dictionary, so we keep them to hand.
    private var pageResources: CGPDFDictionaryRef?

    /// Scans one page. Never throws — a content stream we cannot follow simply
    /// yields fewer images, and the size gate catches the consequences.
    func scan(page: CGPDFPage) {
        if let pageDict = page.dictionary {
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(pageDict, "Resources", &resources) {
                pageResources = resources
            }
        }
        let content = CGPDFContentStreamCreateWithPage(page)
        run(content: content)
        CGPDFContentStreamRelease(content)
    }

    fileprivate func run(content: CGPDFContentStreamRef) {
        guard let table = ContentScanner.operatorTable else { return }
        let info = Unmanaged.passUnretained(self).toOpaque()
        let scanner = CGPDFScannerCreate(content, table, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
    }

    // MARK: - Operator handling

    fileprivate func pushState() {
        stack.append(ctm)
    }

    fileprivate func popState() {
        if let last = stack.popLast() { ctm = last }
    }

    fileprivate func concat(_ m: CGAffineTransform) {
        ctm = m.concatenating(ctm)
    }

    fileprivate func countTextOperator() {
        textOperatorCount += 1
    }

    /// An image drawn under the current CTM occupies the transformed unit square.
    fileprivate func drawnSize() -> (width: Double, height: Double) {
        let width = (ctm.a * ctm.a + ctm.b * ctm.b).squareRoot()
        let height = (ctm.c * ctm.c + ctm.d * ctm.d).squareRoot()
        return (abs(width), abs(height))
    }

    fileprivate func handleXObject(named name: String, content: CGPDFContentStreamRef) {
        guard let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream),
              let stream,
              let dict = CGPDFStreamGetDictionary(stream) else { return }

        var subtypePtr: UnsafePointer<CChar>?
        CGPDFDictionaryGetName(dict, "Subtype", &subtypePtr)
        let subtype = subtypePtr.map { String(cString: $0) } ?? ""

        switch subtype {
        case "Image":
            record(image: dict, stream: stream)
        case "Form":
            recurse(intoForm: stream, dict: dict, parent: content)
        default:
            break
        }
    }

    private func record(image dict: CGPDFDictionaryRef, stream: CGPDFStreamRef) {
        var width: CGPDFInteger = 0
        var height: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dict, "Width", &width),
              CGPDFDictionaryGetInteger(dict, "Height", &height),
              width > 0, height > 0 else { return }

        var bpc: CGPDFInteger = 8
        if !CGPDFDictionaryGetInteger(dict, "BitsPerComponent", &bpc) { bpc = 8 }

        var isMask = false
        CGPDFDictionaryGetBoolean(dict, "ImageMask", &isMask)
        if isMask { bpc = 1 }

        // `/Length` is the encoded size in the file — exactly the number we want
        // for "what is this image costing me", and free to read.
        var length: CGPDFInteger = 0
        CGPDFDictionaryGetInteger(dict, "Length", &length)

        var colorSpaceObject: CGPDFObjectRef?
        CGPDFDictionaryGetObject(dict, "ColorSpace", &colorSpaceObject)
        let colorSpace = isMask
            ? ColorSpaceInfo(name: "ImageMask", componentCount: 1, isIndexed: false, isRebuildable: false)
            : ColorSpaceInfo.parse(colorSpaceObject)

        let filterNames = FilterChain.names(from: dict)
        let filter = FilterChain.imageFilter(filterNames)

        var decodeArray: CGPDFArrayRef?
        let hasDecodeArray = CGPDFDictionaryGetArray(dict, "Decode", &decodeArray)

        let address = UInt(bitPattern: unsafeBitCast(stream, to: Int.self))
        guard let identity = identities.identity(for: address, stream: stream, dict: dict) else { return }

        let size = drawnSize()
        let key = ImageKey(
            pixelWidth: Int(width),
            pixelHeight: Int(height),
            bitsPerComponent: Int(bpc),
            encodedLength: Int(length),
            filter: filter.rawValue
        )

        images.append(RawImage(
            identity: identity,
            key: key,
            pixelWidth: Int(width),
            pixelHeight: Int(height),
            bitsPerComponent: Int(bpc),
            colorSpace: colorSpace,
            filter: filter,
            encodedLength: Int(length),
            mask: ImageFingerprint.describeMask(imageDict: dict),
            hasColourKeyMask: ImageFingerprint.hasColourKeyMask(imageDict: dict),
            hasDecodeArray: hasDecodeArray,
            isStencilMask: isMask,
            objectAddress: address,
            maskObjectAddress: ImageFingerprint.maskStream(imageDict: dict).map {
                UInt(bitPattern: unsafeBitCast($0.0, to: Int.self))
            },
            drawnWidthPoints: size.width,
            drawnHeightPoints: size.height
        ))
    }

    /// Form XObjects nest arbitrarily deep and carry their own `/Matrix`, so an
    /// image inside one is only measurable if we follow it down.
    private func recurse(intoForm stream: CGPDFStreamRef, dict: CGPDFDictionaryRef, parent: CGPDFContentStreamRef) {
        guard depth < Self.maxFormDepth else { return }

        let identity = UInt(bitPattern: unsafeBitCast(stream, to: Int.self))
        guard !formsInProgress.contains(identity) else { return }

        var formResources: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(dict, "Resources", &formResources)
        guard let resources = formResources ?? pageResources else { return }

        var matrixArray: CGPDFArrayRef?
        var matrix = CGAffineTransform.identity
        if CGPDFDictionaryGetArray(dict, "Matrix", &matrixArray), let matrixArray,
           CGPDFArrayGetCount(matrixArray) == 6 {
            var values = [CGPDFReal](repeating: 0, count: 6)
            var ok = true
            for i in 0..<6 {
                var v: CGPDFReal = 0
                if CGPDFArrayGetNumber(matrixArray, i, &v) { values[i] = v } else { ok = false }
            }
            if ok {
                matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2],
                                           d: values[3], tx: values[4], ty: values[5])
            }
        }

        let savedCTM = ctm
        let savedStack = stack
        concat(matrix)
        depth += 1
        formsInProgress.insert(identity)

        let formContent = CGPDFContentStreamCreateWithStream(stream, resources, parent)
        run(content: formContent)
        CGPDFContentStreamRelease(formContent)

        formsInProgress.remove(identity)
        depth -= 1
        ctm = savedCTM
        stack = savedStack
    }

    fileprivate func countInlineImage() {
        // Inline images are capped at 4 KB by the specification, so they never
        // move the needle on file size. We count them and move on.
        inlineImageCount += 1
    }

    // MARK: - Operator table

    /// Built once. `CGPDFOperatorTable` is immutable after setup and CoreGraphics
    /// only reads from it during a scan.
    nonisolated(unsafe) static let operatorTable: CGPDFOperatorTableRef? = {
        guard let table = CGPDFOperatorTableCreate() else { return nil }

        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            ContentScanner.from(info)?.pushState()
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            ContentScanner.from(info)?.popState()
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let state = ContentScanner.from(info) else { return }
            var values = [CGPDFReal](repeating: 0, count: 6)
            // The scanner stack pops in reverse: f, e, d, c, b, a.
            for i in stride(from: 5, through: 0, by: -1) {
                var v: CGPDFReal = 0
                guard CGPDFScannerPopNumber(scanner, &v) else { return }
                values[i] = v
            }
            state.concat(CGAffineTransform(a: values[0], b: values[1], c: values[2],
                                           d: values[3], tx: values[4], ty: values[5]))
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let state = ContentScanner.from(info) else { return }
            var namePtr: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &namePtr), let namePtr else { return }
            let name = String(cString: namePtr)
            state.handleXObject(named: name, content: CGPDFScannerGetContentStream(scanner))
        }
        CGPDFOperatorTableSetCallback(table, "EI") { _, info in
            ContentScanner.from(info)?.countInlineImage()
        }

        for op in ["Tj", "TJ", "'", "\"", "TD", "Td", "T*"] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in
                ContentScanner.from(info)?.countTextOperator()
            }
        }

        return table
    }()

    fileprivate static func from(_ info: UnsafeMutableRawPointer?) -> ContentScanner? {
        guard let info else { return nil }
        return Unmanaged<ContentScanner>.fromOpaque(info).takeUnretainedValue()
    }
}
