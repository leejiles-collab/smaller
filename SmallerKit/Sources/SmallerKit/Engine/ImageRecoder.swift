import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Turns an image XObject into a smaller JPEG, or declines to.
///
/// Declining is a first-class outcome: 1-bit fax scans, anything with an alpha
/// channel, and colorspaces we cannot faithfully rebuild are copied through
/// untouched rather than guessed at.
enum ImageRecoder {

    struct Recoded {
        let jpegData: Data
        let pixelWidth: Int
        let pixelHeight: Int
        let isGrayscale: Bool
        /// Present when the source carried alpha; written as a separate
        /// `/SMask` image alongside the JPEG.
        let mask: RecodedMask?
    }

    /// A soft mask, re-encoded as 8-bit grey.
    ///
    /// Deliberately Flate and never JPEG: lossy artefacts on an alpha channel
    /// show up as halos around every cut-out, and a mask is mostly flat 0 and
    /// 255, which deflates far better than it would ever JPEG.
    struct RecodedMask {
        let data: Data
        let isFlate: Bool
        let pixelWidth: Int
        let pixelHeight: Int
    }

    enum Failure: Error {
        case decodeFailed
        case maskUndecodable
        case notSmaller
    }

    /// Re-encodes `stream` to fit `targetDPI` at `quality`.
    /// Returns the failure reason rather than a bare nil, so the report can show
    /// exactly why an image was left alone.
    static func recode(
        stream: CGPDFStreamRef,
        dict: CGPDFDictionaryRef,
        sourceData: Data,
        sourceFormat: CGPDFDataFormat,
        usage: ImageUsage,
        profile: CompressionProfile,
        grayscale: Bool
    ) -> Result<Recoded, Failure> {
        let scale = SizeEstimator.downsampleScale(for: usage, targetDPI: profile.targetDPI)
        let targetWidth = max(1, Int((Double(usage.pixelWidth) * scale).rounded()))
        let targetHeight = max(1, Int((Double(usage.pixelHeight) * scale).rounded()))

        // Nothing to gain: already at or below target resolution and already a
        // JPEG with no alpha. Re-encoding would only add generational loss.
        if scale >= 0.999 && usage.filter == .dct && usage.mask == nil
            && !grayscale && profile.jpegQuality >= 0.6 {
            return .failure(.notSmaller)
        }

        // The decoded source is the largest thing in memory here — a 3999x2250
        // RGB image is 27 MB — so it is scoped to die before we encode.
        let jpeg: Data
        let finalWidth: Int
        let finalHeight: Int
        do {
            guard let redrawn = autoreleasepool(invoking: { () -> CGImage? in
                guard let source = decode(
                    data: sourceData, format: sourceFormat, stream: stream,
                    usage: usage, maxPixelSize: max(targetWidth, targetHeight)
                ) else { return nil }
                return redraw(source, width: targetWidth, height: targetHeight, grayscale: grayscale)
            }) else {
                return .failure(.decodeFailed)
            }
            finalWidth = redrawn.width
            finalHeight = redrawn.height
            guard let encoded = encodeJPEG(redrawn, quality: profile.jpegQuality) else {
                return .failure(.decodeFailed)
            }
            jpeg = encoded
        }

        var recodedMask: RecodedMask?
        if usage.mask != nil {
            guard let mask = recodeMask(
                imageDict: dict,
                maxWidth: finalWidth,
                maxHeight: finalHeight,
                scale: scale
            ) else {
                return .failure(.maskUndecodable)
            }
            recodedMask = mask
        }

        // The whole point is to be smaller. Compare against what the image and
        // its mask cost together, since we are replacing both.
        let produced = jpeg.count + (recodedMask?.data.count ?? 0)
        guard produced < usage.totalByteLength else { return .failure(.notSmaller) }

        return .success(Recoded(
            jpegData: jpeg,
            pixelWidth: finalWidth,
            pixelHeight: finalHeight,
            isGrayscale: grayscale,
            mask: recodedMask
        ))
    }

    // MARK: - Soft masks

    /// Decodes the attached mask and re-encodes it as 8-bit `/DeviceGray`.
    ///
    /// The mask and the base image are allowed to have different pixel
    /// dimensions — a viewer resamples the mask onto the base image's grid — so
    /// this resamples rather than assuming they line up, and never lets the
    /// mask exceed the base image's new size.
    static func recodeMask(
        imageDict: CGPDFDictionaryRef,
        maxWidth: Int,
        maxHeight: Int,
        scale: Double
    ) -> RecodedMask? {
        guard let (stream, dict, isStencil) = ImageFingerprint.maskStream(imageDict: imageDict) else { return nil }

        var width: CGPDFInteger = 0
        var height: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dict, "Width", &width),
              CGPDFDictionaryGetInteger(dict, "Height", &height),
              width > 0, height > 0 else { return nil }

        var bpc: CGPDFInteger = 8
        if !CGPDFDictionaryGetInteger(dict, "BitsPerComponent", &bpc) { bpc = isStencil ? 1 : 8 }

        let targetWidth = max(1, min(maxWidth, Int((Double(width) * scale).rounded())))
        let targetHeight = max(1, min(maxHeight, Int((Double(height) * scale).rounded())))

        guard let grey = autoreleasepool(invoking: { () -> [UInt8]? in
            guard let image = decodeMaskImage(
                stream: stream, width: Int(width), height: Int(height),
                bitsPerComponent: Int(bpc), isStencil: isStencil
            ) else { return nil }
            return greyBytes(from: image, width: targetWidth, height: targetHeight)
        }) else { return nil }

        let raw = Data(grey)
        if let deflated = Flate.encode(raw) {
            return RecodedMask(data: deflated, isFlate: true, pixelWidth: targetWidth, pixelHeight: targetHeight)
        }
        return RecodedMask(data: raw, isFlate: false, pixelWidth: targetWidth, pixelHeight: targetHeight)
    }

    /// Builds a greyscale `CGImage` for a soft mask or a stencil mask.
    static func decodeMaskImage(
        stream: CGPDFStreamRef,
        width: Int,
        height: Int,
        bitsPerComponent: Int,
        isStencil: Bool
    ) -> CGImage? {
        var format = CGPDFDataFormat.raw
        guard let cfData = CGPDFStreamCopyData(stream, &format) else { return nil }
        let data = cfData as Data

        if format != .raw {
            // A JPEG-coded soft mask. Rare, but ImageIO handles it.
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }

        if bitsPerComponent == 8 {
            let bytesPerRow = width
            guard data.count >= bytesPerRow * height,
                  let provider = CGDataProvider(data: data as CFData) else { return nil }
            return CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )
        }

        guard [1, 2, 4].contains(bitsPerComponent) else { return nil }
        guard let expanded = unpack(
            data, width: width, height: height,
            bitsPerComponent: bitsPerComponent, invert: isStencil
        ) else { return nil }

        guard let provider = CGDataProvider(data: Data(expanded) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// Expands sub-byte samples to 8 bits.
    ///
    /// `invert` is for stencil masks, where a sample of 1 means *masked out* —
    /// the opposite of a soft mask, where 255 means fully opaque.
    static func unpack(_ data: Data, width: Int, height: Int, bitsPerComponent: Int, invert: Bool) -> [UInt8]? {
        let bytesPerRow = (width * bitsPerComponent + 7) / 8
        guard data.count >= bytesPerRow * height else { return nil }

        let maxValue = (1 << bitsPerComponent) - 1
        var out = [UInt8](repeating: 0, count: width * height)
        data.withUnsafeBytes { raw in
            for y in 0..<height {
                let rowStart = y * bytesPerRow
                for x in 0..<width {
                    let bitOffset = x * bitsPerComponent
                    let byte = raw[rowStart + bitOffset / 8]
                    let shift = 8 - bitsPerComponent - (bitOffset % 8)
                    let sample = Int((byte >> UInt8(shift)) & UInt8(maxValue))
                    let scaled = UInt8(sample * 255 / maxValue)
                    out[y * width + x] = invert ? 255 &- scaled : scaled
                }
            }
        }
        return out
    }

    /// Resamples a greyscale image into a tightly packed 8-bit buffer.
    static func greyBytes(from image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: width * height)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buffer : nil
    }

    // MARK: - Decoding

    /// Gets pixels back out of a PDF image stream.
    ///
    /// `CGPDFStreamCopyData` applies the byte-level filters (Flate, LZW, ASCII85,
    /// RunLength) and reports whether what is left is still JPEG or JPEG 2000.
    /// There is no public API for the untouched bytes, so this is the seam. The
    /// caller has already paid for that copy, so it passes the bytes in.
    static func decode(
        data: Data,
        format: CGPDFDataFormat,
        stream: CGPDFStreamRef,
        usage: ImageUsage,
        maxPixelSize: Int
    ) -> CGImage? {
        switch format {
        case .jpegEncoded, .JPEG2000:
            return decodeViaImageIO(data, maxPixelSize: maxPixelSize)
        case .raw:
            return decodeRawSamples(data, stream: stream, usage: usage)
        @unknown default:
            return nil
        }
    }

    /// ImageIO downsamples during decode, so a 40 MP JPEG never has to exist at
    /// full size in memory. This is what keeps the share extension alive.
    private static func decodeViaImageIO(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return thumb
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Rebuilds a `CGImage` from unfiltered PDF samples.
    private static func decodeRawSamples(_ data: Data, stream: CGPDFStreamRef, usage: ImageUsage) -> CGImage? {
        let width = usage.pixelWidth
        let height = usage.pixelHeight
        let bpc = usage.bitsPerComponent

        if usage.colorSpaceName == "Indexed" {
            return decodeIndexed(data, stream: stream, usage: usage)
        }

        let components = usage.componentCount
        guard components == 1 || components == 3 || components == 4 else { return nil }
        guard bpc == 8 || bpc == 16 else { return nil }

        let bitsPerPixel = components * bpc
        let bytesPerRow = (width * bitsPerPixel + 7) / 8
        guard data.count >= bytesPerRow * height else { return nil }

        let space: CGColorSpace = switch components {
        case 1: CGColorSpaceCreateDeviceGray()
        case 3: CGColorSpaceCreateDeviceRGB()
        default: CGColorSpaceCreateDeviceCMYK()
        }

        var bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        if bpc == 16 { bitmapInfo.insert(.byteOrder16Big) }

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: bpc,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// Indexed images store palette offsets; we expand them to 8-bit samples.
    private static func decodeIndexed(_ data: Data, stream: CGPDFStreamRef, usage: ImageUsage) -> CGImage? {
        guard let dict = CGPDFStreamGetDictionary(stream) else { return nil }
        var colorSpaceObject: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dict, "ColorSpace", &colorSpaceObject), let colorSpaceObject else { return nil }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(colorSpaceObject, .array, &array), let array,
              CGPDFArrayGetCount(array) >= 4 else { return nil }

        var baseObject: CGPDFObjectRef?
        guard CGPDFArrayGetObject(array, 1, &baseObject) else { return nil }
        let base = ColorSpaceInfo.parse(baseObject)
        guard base.componentCount == 1 || base.componentCount == 3 else { return nil }

        guard let palette = paletteBytes(array) else { return nil }

        let width = usage.pixelWidth
        let height = usage.pixelHeight
        let bpc = usage.bitsPerComponent
        guard [1, 2, 4, 8].contains(bpc) else { return nil }

        let n = base.componentCount
        let bytesPerRow = (width * bpc + 7) / 8
        guard data.count >= bytesPerRow * height else { return nil }

        var out = [UInt8](repeating: 0, count: width * height * n)
        let maxIndex = palette.count / n

        data.withUnsafeBytes { raw in
            for y in 0..<height {
                let rowStart = y * bytesPerRow
                for x in 0..<width {
                    let bitOffset = x * bpc
                    let byte = raw[rowStart + bitOffset / 8]
                    let shift = 8 - bpc - (bitOffset % 8)
                    let mask = UInt8((1 << bpc) - 1)
                    let index = Int((byte >> UInt8(shift)) & mask)
                    let clamped = min(index, max(0, maxIndex - 1))
                    let dst = (y * width + x) * n
                    for c in 0..<n {
                        out[dst + c] = palette[clamped * n + c]
                    }
                }
            }
        }

        let space = n == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8 * n,
            bytesPerRow: width * n,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// The lookup table is either a literal string or a stream.
    private static func paletteBytes(_ colorSpaceArray: CGPDFArrayRef) -> [UInt8]? {
        var stringRef: CGPDFStringRef?
        if CGPDFArrayGetString(colorSpaceArray, 3, &stringRef), let stringRef,
           let bytes = CGPDFStringGetBytePtr(stringRef) {
            let length = CGPDFStringGetLength(stringRef)
            return Array(UnsafeBufferPointer(start: bytes, count: length))
        }
        var streamRef: CGPDFStreamRef?
        if CGPDFArrayGetStream(colorSpaceArray, 3, &streamRef), let streamRef {
            var format = CGPDFDataFormat.raw
            if let data = CGPDFStreamCopyData(streamRef, &format), format == .raw {
                return [UInt8](data as Data)
            }
        }
        return nil
    }

    // MARK: - Redraw and encode

    /// Draws into a known colorspace at the target size. This also launders
    /// CMYK and exotic profiles into something JPEG can carry safely.
    static func redraw(_ image: CGImage, width: Int, height: Int, grayscale: Bool) -> CGImage? {
        guard let context = bitmapContext(width: width, height: height, grayscale: grayscale) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// CoreGraphics has no 24-bit RGB bitmap context, so anything we render into
    /// is 32-bit RGBX.
    static func bitmapContext(width: Int, height: Int, grayscale: Bool) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: grayscale ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        )
    }

    static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
