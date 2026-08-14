import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SmallerKit

/// Renders a page of two PDFs side by side so quality can be eyeballed rather
/// than argued about.
enum Render {

    static let dpi: Double = 110

    static func sideBySide(
        original: URL,
        output: URL,
        page pageNumber: Int = 1,
        dpi: Double = Render.dpi,
        to destination: URL
    ) {
        guard let left = page(pageNumber, of: original, dpi: dpi),
              let right = page(pageNumber, of: output, dpi: dpi) else { return }

        let gap = 24
        let width = left.width + right.width + gap
        let height = max(left.height, right.height)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return }

        context.setFillColor(gray: 0.85, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(left, in: CGRect(x: 0, y: height - left.height, width: left.width, height: left.height))
        context.draw(right, in: CGRect(x: left.width + gap, y: height - right.height, width: right.width, height: right.height))

        guard let image = context.makeImage() else { return }
        writePNG(image, to: destination)
    }

    /// `pageNumber` is 1-based, matching how a reader counts pages.
    static func page(_ pageNumber: Int, of url: URL, dpi: Double = Render.dpi) -> CGImage? {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: pageNumber) else { return nil }
        var box = page.getBoxRect(.cropBox)
        if box.isNull || box.isEmpty { box = page.getBoxRect(.mediaBox) }
        guard box.width > 0, box.height > 0 else { return nil }

        let display = PageGeometry.displaySize(box: box, rotation: Int(page.rotationAngle))
        let scale = dpi / 72.0
        let width = max(1, Int((display.width * scale).rounded()))
        let height = max(1, Int((display.height * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        // Not `getDrawingTransform`: it refuses to scale a page up, so anything
        // rendered above 72 DPI would come back at 1:1 with margins.
        context.concatenate(PageGeometry.transform(
            box: box,
            rotation: Int(page.rotationAngle),
            pixelSize: CGSize(width: width, height: height)
        ))
        context.drawPDFPage(page)
        return context.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
