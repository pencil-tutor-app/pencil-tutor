import PencilKit
import UIKit

/// A downscaled picture of the page for the tutor.
struct PageSnapshot {
    let png: Data
    let pixelWidth: Int
    let pixelHeight: Int
    /// Pixels per canvas point. Multiply canvas distances by this to get image distances.
    let scale: CGFloat
    /// The part of the page in the picture, in canvas (page) points. The picture's top-left pixel is `region.origin`, so a point
    /// `p` on the page is at pixel `((p.x - region.minX) * scale, (p.y - region.minY) * scale)`.
    let region: CGRect

    /// True when most of the line is inside the picture, so the tutor can see it and may be told to circle it.
    func shows(_ line: InkLine) -> Bool {
        line.box.midY >= region.minY && line.box.midY <= region.maxY
    }
}

/// The size of the endless page and where things sit on it. Pure arithmetic with no UIKit, so it is unit tested.
///
/// Everything is in page points: the canvas's drawing coordinates, which are also its content coordinates, so the y of a
/// stroke, of a line box and of a mark is the same number no matter how far the page is scrolled.
enum PageGeometry {
    /// How close to the screen edges a mark and its callout may sit before the page scrolls to bring them back.
    static let calloutAllowance: CGFloat = 80

    /// The page is the ink plus one more screen of blank paper below it, and never shorter than the screen.
    /// No ink: exactly one screen (nothing to scroll). Ink ending 300 pt down a 820 pt screen: 1120 pt. It grows as the student
    /// writes and shrinks when ink is deleted or erased. Rounded up to whole points so tiny float changes do not resize the page.
    static func contentHeight(viewportHeight: CGFloat, inkBottom: CGFloat?) -> CGFloat {
        guard let inkBottom, inkBottom.isFinite else { return ceil(viewportHeight) }
        return ceil(max(viewportHeight, inkBottom + viewportHeight))
    }

    /// The furthest the page can be scrolled (never negative).
    static func maxOffsetY(contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        max(0, contentHeight - viewportHeight)
    }

    static func clampedOffsetY(_ y: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        min(max(0, y), maxOffsetY(contentHeight: contentHeight, viewportHeight: viewportHeight))
    }

    /// Where to scroll so a mark (and the callout beside or under it) is on screen. Nil when it already is.
    /// Aims the mark about a third of the way down the screen, which leaves room for a callout below it.
    static func offsetToReveal(box: CGRect, currentOffsetY: CGFloat, viewportHeight: CGFloat, contentHeight: CGFloat) -> CGFloat? {
        let visibleTop = currentOffsetY + calloutAllowance
        let visibleBottom = currentOffsetY + viewportHeight - calloutAllowance
        if box.minY >= visibleTop && box.maxY <= visibleBottom { return nil }
        let wanted = box.midY - viewportHeight * 0.35
        let target = clampedOffsetY(wanted, contentHeight: contentHeight, viewportHeight: viewportHeight)
        return abs(target - currentOffsetY) < 1 ? nil : target
    }
}

enum PageSnapshotter {
    /// Longest side of the image in pixels (plan amendment 5; the server rejects anything longer).
    static let maxLongSide: CGFloat = 1024
    /// Largest PNG we will send (plan amendment 5).
    static let maxBytes = 400_000
    /// Blank paper kept under the lowest ink in the picture, in page points.
    static let marginBelowInk: CGFloat = 40
    /// The smallest picture scale a tall page may be squeezed to before the window slides instead. Handwriting about 35 pt
    /// tall is still about 19 px tall at 0.55; much smaller and the tutor starts misreading digits.
    static let minLegibleScale: CGFloat = 0.55

    /// Which part of the page goes into the picture, and how big it is drawn.
    ///
    /// The rule (the page is endless, the picture is not):
    ///  1. Start from what a one-screen page always got: the screen's width and height, scaled so the longer side is at most
    ///     1024 px (`baseScale`). A page that fits on the first screen produces exactly the picture it did before the page
    ///     scrolled, so the tutor's measured behaviour is unchanged.
    ///  2. If ink runs below the screen, extend the picture downward to the lowest ink plus `marginBelowInk`, and shrink the
    ///     scale so the picture's longer side stays within 1024 px (the server rejects longer, and image tokens are billed by
    ///     size, so a long page costs about what a short one does).
    ///  3. Never shrink below `minLegibleScale`. If the page is longer than 1024 px / that scale (about 1860 pt, a bit over two
    ///     screens), the window slides instead: it ends under the lowest ink and starts as far up as fits. Work scrolled out
    ///     of the window is not in the picture and its lines are not sent; it was in earlier looks, and the student writes
    ///     downward, so the newest work is the part worth reading.
    static func region(canvasSize: CGSize, inkBottom: CGFloat?) -> (rect: CGRect, scale: CGFloat) {
        let baseScale = min(1, maxLongSide / max(canvasSize.width, canvasSize.height))
        let floorScale = min(baseScale, minLegibleScale)
        let bottom = max(canvasSize.height, (inkBottom.flatMap { $0.isFinite ? $0 : nil } ?? 0) + marginBelowInk)
        let tallestAllowed = maxLongSide / floorScale
        let top = max(0, bottom - tallestAllowed)
        let rect = CGRect(x: 0, y: top, width: canvasSize.width, height: bottom - top)
        let scale = min(baseScale, maxLongSide / rect.height)
        return (rect, scale)
    }

    /// Renders the ink on white with faint line numbers in the left margin.
    /// `canvasSize` is the visible size of the canvas (the width of the page and the height of one screen); the ink can be
    /// taller than that, see `region`. If the PNG is over the size limit, the picture is shrunk a little at a time; it never
    /// grows past 1024 px.
    static func make(drawing: PKDrawing, canvasSize: CGSize, lines: [InkLine]) throws -> PageSnapshot {
        guard canvasSize.width > 1, canvasSize.height > 1 else {
            throw TutorError.snapshotFailed(detail: "canvas has no size (\(Int(canvasSize.width))x\(Int(canvasSize.height)))")
        }
        let inkBottom = lines.map { $0.box.maxY }.max()
        let (rect, startScale) = region(canvasSize: canvasSize, inkBottom: inkBottom)
        var scale = startScale
        for _ in 0..<6 {
            let snapshot = render(drawing: drawing, region: rect, lines: lines, scale: scale)
            if snapshot.png.count <= maxBytes { return snapshot }
            scale *= 0.8
        }
        throw TutorError.snapshotFailed(detail: "page image stayed over \(maxBytes) bytes after shrinking")
    }

    private static func render(drawing: PKDrawing, region: CGRect, lines: [InkLine], scale: CGFloat) -> PageSnapshot {
        let pixelSize = CGSize(width: max(1, (region.width * scale).rounded()),
                               height: max(1, (region.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)

        var inkImage = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            inkImage = drawing.image(from: region, scale: scale)
        }

        let numberFont = UIFont.systemFont(ofSize: max(11, 13 * scale), weight: .regular)
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: UIColor(white: 0.55, alpha: 0.9)
        ]

        let png = renderer.pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pixelSize))
            inkImage.draw(in: CGRect(origin: .zero, size: pixelSize))
            for line in lines where line.box.midY >= region.minY && line.box.midY <= region.maxY {
                let label = "\(line.index)" as NSString
                let labelSize = label.size(withAttributes: numberAttributes)
                let x: CGFloat = line.isSideCalculation
                    ? max(2, line.box.minX * scale - labelSize.width - 4)
                    : 4
                let y = max(0, (line.box.midY - region.minY) * scale - labelSize.height / 2)
                label.draw(at: CGPoint(x: x, y: y), withAttributes: numberAttributes)
            }
        }
        return PageSnapshot(png: png, pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height),
                            scale: scale, region: region)
    }
}

extension LineWire {
    /// Converts a line from page points to the snapshot's pixel space. `regionTop` is the page y of the picture's top edge
    /// (`PageSnapshot.region.minY`), 0 unless a long page's window slid down.
    init(_ line: InkLine, scale: CGFloat, regionTop: CGFloat = 0) {
        self.init(
            index: line.index,
            box: BoxWire(
                x: Double(line.box.minX * scale),
                y: Double((line.box.minY - regionTop) * scale),
                w: Double(line.box.width * scale),
                h: Double(line.box.height * scale)
            ),
            lastStrokeAt: TimeText.iso(line.lastStrokeAt)
        )
    }
}
