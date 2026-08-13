import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Renders page 1 of two PDFs side by side so quality can be eyeballed rather
/// than argued about.
enum Render {

    static let dpi: Double = 110

    static func sideBySide(original: URL, output: URL, to destination: URL) {
        guard let left = firstPage(of: original), let right = firstPage(of: output) else { return }

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

    static func firstPage(of url: URL) -> CGImage? {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else { return nil }
        var box = page.getBoxRect(.cropBox)
        if box.isNull || box.isEmpty { box = page.getBoxRect(.mediaBox) }
        guard box.width > 0, box.height > 0 else { return nil }

        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let rotated = rotation == 90 || rotation == 270
        let scale = dpi / 72.0
        let width = max(1, Int(((rotated ? box.height : box.width) * scale).rounded()))
        let height = max(1, Int(((rotated ? box.width : box.height) * scale).rounded()))

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
        let destination = CGRect(x: 0, y: 0, width: width, height: height)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: destination, rotate: 0, preserveAspectRatio: true))
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
