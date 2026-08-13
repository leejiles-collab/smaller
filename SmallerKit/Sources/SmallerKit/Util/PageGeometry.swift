import Foundation
import CoreGraphics

/// Maps a PDF page onto a bitmap of a chosen size.
///
/// `CGPDFPage.getDrawingTransform` cannot be used for this. It refuses to scale
/// a page *up*: hand it a destination larger than the page and it centres the
/// page at 1:1 and leaves white margins around it. Rendering a 612x792 page for
/// a 150 DPI raster asks for a 1275x1650 bitmap, so every scan-like page above
/// 72 DPI came out at original size in the middle of an empty sheet — visibly
/// wrong, and invisible to every check except comparing against the original.
public enum PageGeometry {

    /// Size in points a page occupies once its `/Rotate` is applied.
    public static func displaySize(box: CGRect, rotation: Int) -> CGSize {
        let normalized = ((rotation % 360) + 360) % 360
        let quarterTurned = normalized == 90 || normalized == 270
        return CGSize(
            width: quarterTurned ? box.height : box.width,
            height: quarterTurned ? box.width : box.height
        )
    }

    /// Transform that maps the page's own coordinate space onto a bitmap of
    /// `pixelSize`, applying rotation and scaling in both directions.
    public static func transform(box: CGRect, rotation: Int, pixelSize: CGSize) -> CGAffineTransform {
        let display = displaySize(box: box, rotation: rotation)
        guard display.width > 0, display.height > 0 else { return .identity }

        let scaleX = pixelSize.width / display.width
        let scaleY = pixelSize.height / display.height

        var transform = CGAffineTransform(scaleX: scaleX, y: scaleY)

        switch ((rotation % 360) + 360) % 360 {
        case 90:
            transform = transform
                .translatedBy(x: box.height, y: 0)
                .rotated(by: .pi / 2)
        case 180:
            transform = transform
                .translatedBy(x: box.width, y: box.height)
                .rotated(by: .pi)
        case 270:
            transform = transform
                .translatedBy(x: 0, y: box.width)
                .rotated(by: -.pi / 2)
        default:
            break
        }

        // A crop box need not start at the origin.
        return transform.translatedBy(x: -box.origin.x, y: -box.origin.y)
    }

    /// Renders a page into a bitmap context that already exists.
    public static func draw(page: CGPDFPage, into context: CGContext, pixelWidth: Int, pixelHeight: Int) {
        let box = InventoryBuilder.pageBox(page)
        context.concatenate(transform(
            box: box,
            rotation: Int(page.rotationAngle),
            pixelSize: CGSize(width: pixelWidth, height: pixelHeight)
        ))
        context.drawPDFPage(page)
    }
}
