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
    }

    /// Re-encodes `stream` to fit `targetDPI` at `quality`.
    /// Returns nil when we decline, or when the result is not actually smaller.
    static func recode(
        stream: CGPDFStreamRef,
        usage: ImageUsage,
        profile: CompressionProfile,
        grayscale: Bool,
        originalLength: Int
    ) -> Recoded? {
        guard usage.isRecodable else { return nil }

        let scale = SizeEstimator.downsampleScale(for: usage, targetDPI: profile.targetDPI)
        let targetWidth = max(1, Int((Double(usage.pixelWidth) * scale).rounded()))
        let targetHeight = max(1, Int((Double(usage.pixelHeight) * scale).rounded()))

        // Nothing to gain: already at or below target resolution and already a
        // JPEG. Re-encoding would only add generational loss.
        if scale >= 0.999 && usage.filter == .dct && !grayscale && profile.jpegQuality >= 0.6 {
            return nil
        }

        guard let source = decode(stream: stream, usage: usage, maxPixelSize: max(targetWidth, targetHeight)) else {
            return nil
        }

        guard let redrawn = redraw(source, width: targetWidth, height: targetHeight, grayscale: grayscale) else {
            return nil
        }

        guard let data = encodeJPEG(redrawn, quality: profile.jpegQuality) else { return nil }

        // The whole point is to be smaller. If we are not, keep the original.
        guard data.count < originalLength else { return nil }

        return Recoded(
            jpegData: data,
            pixelWidth: redrawn.width,
            pixelHeight: redrawn.height,
            isGrayscale: grayscale
        )
    }

    // MARK: - Decoding

    /// Gets pixels back out of a PDF image stream.
    ///
    /// `CGPDFStreamCopyData` applies the byte-level filters (Flate, LZW, ASCII85,
    /// RunLength) and reports whether what is left is still JPEG or JPEG 2000.
    /// There is no public API for the untouched bytes, so this is the seam.
    static func decode(stream: CGPDFStreamRef, usage: ImageUsage, maxPixelSize: Int) -> CGImage? {
        var format = CGPDFDataFormat.raw
        guard let cfData = CGPDFStreamCopyData(stream, &format) else { return nil }
        let data = cfData as Data

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
        let space = grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = grayscale
            ? CGImageAlphaInfo.none.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
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
