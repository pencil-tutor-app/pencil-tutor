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
        region.contains(CGPoint(x: line.box.midX, y: line.box.midY))
    }
}

/// The size of the endless page and where things sit on it. Pure arithmetic with no UIKit, so it is unit tested.
///
/// The page is endless in every direction (2026-11-14) and zooms from 0.5x to 3x. Everything here is in page points: the
/// canvas's drawing coordinates, which are also its content coordinates (unzoomed), so the x and y of a stroke, a line box and a
/// mark are the same numbers whatever the scroll position or zoom. Only `visibleRect` and the overlay convert to screen points
/// (`screen = page * zoom - contentOffset`).
///
/// How "endless" works with a scroll view that cannot have negative content coordinates:
///  - The first screen (`homeRect`) sits `homeReserve` points in from the top-left corner, so there is blank page to write on
///    left of and above it from the start. Drawing coordinates never change for a normal session.
///  - The page grows right and down just by getting bigger: `contentSize` is the first screen and the ink, plus one screen.
///  - If ink gets within `inkMargin` of the left or top edge (writing more than about 1800 pt left of or above the first
///    screen), the whole drawing is moved right/down by `reanchorShift`, the scroll position moves with it so nothing seems to
///    move, and the tutor's marks move too. That is the only time drawing coordinates change; the session logs `page_reanchored`.
enum PageGeometry {
    /// How close to the screen edges a mark and its callout may sit before the page scrolls to bring them back (screen points).
    static let calloutAllowance: CGFloat = 80
    /// Blank page between the top-left corner of the content and the first screen, in page points.
    static let homeReserve: CGFloat = 3000
    static let minZoom: CGFloat = 0.5
    static let maxZoom: CGFloat = 3
    /// The most blank paper kept between ink and the left/top edge of the content before the page re-anchors. Always below
    /// `homeReserve`, so a re-anchor (which restores `homeReserve`) clearly leaves room.
    static let maxInkMargin: CGFloat = 1200
    /// Re-anchor shifts are rounded up to this, so repeated small shifts do not happen.
    static let shiftStep: CGFloat = 100

    /// Where the first screen is on the page.
    static func homeRect(viewport: CGSize) -> CGRect {
        CGRect(x: homeReserve, y: homeReserve, width: viewport.width, height: viewport.height)
    }

    /// Blank paper wanted between the ink and the edge of the page: about one screen, never more than `maxInkMargin`.
    static func inkMargin(viewport: CGSize) -> CGSize {
        CGSize(width: min(viewport.width, maxInkMargin), height: min(viewport.height, maxInkMargin))
    }

    /// The page, in unzoomed page points: from the top-left corner of the content to one screen past the farther of the first
    /// screen and the ink, in each direction. No ink: the first screen plus its reserve plus one more screen right and down.
    /// Rounded up to whole points so tiny float changes do not resize the page. A non-finite ink bound is ignored.
    static func contentSize(viewport: CGSize, ink: CGRect?) -> CGSize {
        var covered = homeRect(viewport: viewport)
        if let ink, isUsable(ink) { covered = covered.union(ink) }
        return CGSize(width: ceil(covered.maxX + viewport.width), height: ceil(covered.maxY + viewport.height))
    }

    /// How far to move the whole drawing right and down so ink that has come close to the left/top edge has room again.
    /// Nil when the ink is far enough from both edges.
    static func reanchorShift(viewport: CGSize, ink: CGRect?) -> CGSize? {
        guard let ink, isUsable(ink) else { return nil }
        let margin = inkMargin(viewport: viewport)
        let dx = ink.minX < margin.width ? roundedUp(homeReserve - ink.minX) : 0
        let dy = ink.minY < margin.height ? roundedUp(homeReserve - ink.minY) : 0
        return dx > 0 || dy > 0 ? CGSize(width: dx, height: dy) : nil
    }

    /// The part of the page on screen, in page points. `offset` and `viewport` are screen points; `zoom` is the zoom scale.
    static func visibleRect(offset: CGPoint, viewport: CGSize, zoom: CGFloat) -> CGRect {
        let z = max(zoom, 0.01)
        return CGRect(x: offset.x / z, y: offset.y / z, width: viewport.width / z, height: viewport.height / z)
    }

    /// Keeps the scroll position inside the page. `contentSize` is the size the scroll view reports (zoomed).
    static func clampedOffset(_ offset: CGPoint, contentSize: CGSize, viewport: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, offset.x), max(0, contentSize.width - viewport.width)),
                y: min(max(0, offset.y), max(0, contentSize.height - viewport.height)))
    }

    /// Where to scroll so a mark (and the callout beside or under it) is on screen. Nil when it already is.
    /// A mark that is off screen or inside `calloutAllowance` of an edge is brought to the middle of the screen horizontally and
    /// about a third of the way down, which leaves room for a callout below it. The zoom does not change (the student chose it).
    static func offsetToReveal(box: CGRect, offset: CGPoint, zoom: CGFloat, viewport: CGSize, contentSize: CGSize) -> CGPoint? {
        let allowance = calloutAllowance / max(zoom, 0.01)
        let visible = visibleRect(offset: offset, viewport: viewport, zoom: zoom)
        let safe = visible.insetBy(dx: min(allowance, visible.width / 2), dy: min(allowance, visible.height / 2))
        if safe.contains(box.origin) && safe.contains(CGPoint(x: box.maxX, y: box.maxY)) { return nil }
        let inX = box.minX >= safe.minX && box.maxX <= safe.maxX
        let wanted = CGPoint(x: inX ? offset.x : box.midX * zoom - viewport.width * 0.5,
                             y: box.midY * zoom - viewport.height * 0.35)
        let target = clampedOffset(wanted, contentSize: contentSize, viewport: viewport)
        return abs(target.x - offset.x) < 1 && abs(target.y - offset.y) < 1 ? nil : target
    }

    static func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
    }

    private static func roundedUp(_ value: CGFloat) -> CGFloat {
        ceil(value / shiftStep) * shiftStep
    }
}

enum PageSnapshotter {
    /// Longest side of the image in pixels (plan amendment 5; the server rejects anything longer).
    static let maxLongSide: CGFloat = 1024
    /// Largest PNG we will send (plan amendment 5).
    static let maxBytes = 400_000
    /// Blank paper kept around the ink in the picture, in page points.
    static let inkMargin: CGFloat = 40
    /// The smallest picture scale a big page may be squeezed to before the window slides instead. Handwriting about 35 pt
    /// tall is still about 19 px tall at 0.55; much smaller and the tutor starts misreading digits.
    static let minLegibleScale: CGFloat = 0.55

    /// Which part of the page goes into the picture, and how big it is drawn.
    ///
    /// The rule (the page is endless in every direction, the picture is not):
    ///  1. Start from what a one-screen page always got: the first screen, scaled so the longer side is at most 1024 px
    ///     (`baseScale`). Ink that fits on the first screen (with the 40 pt margin) produces exactly that picture, so the
    ///     tutor's measured behaviour is unchanged.
    ///  2. Otherwise the picture is the box around all the ink plus `inkMargin`, widened to at least one screen, and joined
    ///     with the first screen when the ink touches it (so a page that grows downward from the first screen still shows its
    ///     top, as before). The scale drops so the longer side stays within 1024 px (image tokens are billed by size, so a big
    ///     page costs about what a small one does).
    ///  3. Never shrink below `minLegibleScale`. If the box is bigger than 1024 px / that scale (about 1860 pt) in either
    ///     direction, the window slides instead: it is as big as the limit allows, ends just past the most recent line (the
    ///     student's newest work, in both directions) and is kept inside the ink's box. Lines whose middle is outside the window
    ///     are not sent that look; they were in earlier looks.
    /// `newestBox` is the box of the line written last; without it the window is anchored on the far corner of the ink.
    static func region(canvasSize: CGSize, inkBox: CGRect?, newestBox: CGRect? = nil) -> (rect: CGRect, scale: CGFloat) {
        let home = PageGeometry.homeRect(viewport: canvasSize)
        let baseScale = min(1, maxLongSide / max(canvasSize.width, canvasSize.height))
        guard let inkBox, PageGeometry.isUsable(inkBox) else { return (home, baseScale) }
        let padded = inkBox.insetBy(dx: -inkMargin, dy: -inkMargin)
        if home.contains(padded) { return (home, baseScale) }

        var want = padded
        if home.intersects(inkBox) { want = want.union(home) }
        if want.width < canvasSize.width {
            want = CGRect(x: want.midX - canvasSize.width / 2, y: want.minY, width: canvasSize.width, height: want.height)
        }
        if want.height < canvasSize.height {
            want = CGRect(x: want.minX, y: want.midY - canvasSize.height / 2, width: want.width, height: canvasSize.height)
        }

        let floorScale = min(baseScale, minLegibleScale)
        let longestAllowed = maxLongSide / floorScale
        var rect = want
        if want.width > longestAllowed || want.height > longestAllowed {
            let size = CGSize(width: min(want.width, longestAllowed), height: min(want.height, longestAllowed))
            let anchor = (newestBox.flatMap { PageGeometry.isUsable($0) ? $0 : nil }) ?? inkBox
            let farX = min(want.maxX, anchor.maxX + inkMargin)
            let farY = min(want.maxY, anchor.maxY + inkMargin)
            let originX = min(max(want.minX, farX - size.width), want.maxX - size.width)
            let originY = min(max(want.minY, farY - size.height), want.maxY - size.height)
            rect = CGRect(origin: CGPoint(x: originX, y: originY), size: size)
        }
        let scale = min(baseScale, maxLongSide / max(rect.width, rect.height))
        return (rect, scale)
    }

    /// Renders the ink on white with faint line numbers in the left margin.
    /// `canvasSize` is the visible size of the canvas (one screen); the ink can be anywhere on the page, see `region`. If the
    /// PNG is over the size limit, the picture is shrunk a little at a time; it never grows past 1024 px.
    static func make(drawing: PKDrawing, canvasSize: CGSize, lines: [InkLine]) throws -> PageSnapshot {
        guard canvasSize.width > 1, canvasSize.height > 1 else {
            throw TutorError.snapshotFailed(detail: "canvas has no size (\(Int(canvasSize.width))x\(Int(canvasSize.height)))")
        }
        let inkBox = lines.map { $0.box }.reduce(CGRect.null) { $0.union($1) }
        let newest = lines.max { $0.lastStrokeAt < $1.lastStrokeAt }?.box
        let (rect, startScale) = region(canvasSize: canvasSize, inkBox: inkBox.isNull ? nil : inkBox, newestBox: newest)
        let wide = rect.width > canvasSize.width * 1.05
        var scale = startScale
        for _ in 0..<6 {
            let snapshot = render(drawing: drawing, region: rect, lines: lines, scale: scale, labelsBesideLines: wide)
            if snapshot.png.count <= maxBytes { return snapshot }
            scale *= 0.8
        }
        throw TutorError.snapshotFailed(detail: "page image stayed over \(maxBytes) bytes after shrinking")
    }

    /// `labelsBesideLines`: on a picture wider than one screen a number in the far-left margin would be a long way from its
    /// line, so every number sits just left of its line instead (side calculations always did).
    private static func render(drawing: PKDrawing, region: CGRect, lines: [InkLine], scale: CGFloat,
                               labelsBesideLines: Bool) -> PageSnapshot {
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
            for line in lines where region.contains(CGPoint(x: line.box.midX, y: line.box.midY)) {
                let label = "\(line.index)" as NSString
                let labelSize = label.size(withAttributes: numberAttributes)
                let x: CGFloat = (line.isSideCalculation || labelsBesideLines)
                    ? max(2, (line.box.minX - region.minX) * scale - labelSize.width - 4)
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
    /// Converts a line from page points to the snapshot's pixel space. `regionOrigin` is the page point of the picture's
    /// top-left corner (`PageSnapshot.region.origin`).
    init(_ line: InkLine, scale: CGFloat, regionOrigin: CGPoint = .zero) {
        self.init(
            index: line.index,
            box: BoxWire(
                x: Double((line.box.minX - regionOrigin.x) * scale),
                y: Double((line.box.minY - regionOrigin.y) * scale),
                w: Double(line.box.width * scale),
                h: Double(line.box.height * scale)
            ),
            lastStrokeAt: TimeText.iso(line.lastStrokeAt)
        )
    }
}
