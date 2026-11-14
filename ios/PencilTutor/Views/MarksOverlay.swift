import SwiftUI

/// The tutor's marks, drawn above the canvas and separate from the student's ink.
/// Touches pass straight through to the canvas underneath.
///
/// The page scrolls and zooms, the overlay does not: a mark's box is in page points (the same numbers as the ink and the line
/// boxes), so it is multiplied by the zoom and the whole layer is shifted up and left by the canvas's scroll offset
/// (`screen = page * zoom - offset`), which keeps a circle on its line while the page moves or is pinched. Only the circle
/// scales; the callout keeps its reading size at any zoom. The overlay's own frame is the visible canvas, so anything scrolled
/// off screen is clipped. The callout is placed against the part of the page on screen (beside, under or above the circle),
/// so it never runs off the right or bottom edge; a mark off screen is scrolled into view first (`offsetToReveal`).
struct MarksOverlay: View {
    let marks: [Mark]
    @ObservedObject var viewport: CanvasViewport

    var body: some View {
        GeometryReader { proxy in
            let pageSize = CGSize(width: max(proxy.size.width, viewport.contentSize.width),
                                  height: max(proxy.size.height, viewport.contentSize.height))
            ZStack(alignment: .topLeading) {
                ForEach(marks) { mark in
                    MarkView(mark: mark, zoom: viewport.zoomScale, pageSize: pageSize,
                             visible: CGRect(origin: viewport.offset, size: proxy.size))
                }
            }
            .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
            .offset(x: -viewport.offset.x, y: -viewport.offset.y)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

private struct MarkView: View {
    let mark: Mark
    let zoom: CGFloat
    /// The whole page in screen points (zoomed).
    let pageSize: CGSize
    /// The part of the (zoomed) page on screen, in the same points as `pageSize`.
    let visible: CGRect

    private let calloutWidth: CGFloat = 260
    private let calloutHeight: CGFloat = 64

    /// The circle, in screen points of the zoomed page: the line's box with room round it, scaled with the page.
    private var ellipseRect: CGRect {
        let padded = mark.box.insetBy(dx: -22, dy: -14)
        let scaled = CGRect(x: padded.minX * zoom, y: padded.minY * zoom, width: padded.width * zoom, height: padded.height * zoom)
        let clippedMinX = max(2, scaled.minX)
        let clippedMinY = max(2, scaled.minY)
        let clippedMaxX = min(pageSize.width - 2, scaled.maxX)
        let clippedMaxY = min(pageSize.height - 2, scaled.maxY)
        return CGRect(x: clippedMinX, y: clippedMinY,
                      width: max(20, clippedMaxX - clippedMinX), height: max(20, clippedMaxY - clippedMinY))
    }

    /// Beside the circle if it fits on screen, else under it, else above it; always kept inside the visible part of the page.
    private var calloutOrigin: CGPoint {
        CalloutPlacement.origin(circle: ellipseRect, visible: visible.intersection(CGRect(origin: .zero, size: pageSize)),
                                size: CGSize(width: calloutWidth, height: calloutHeight))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Ellipse()
                .stroke(Color.red, lineWidth: 4)
                .frame(width: ellipseRect.width, height: ellipseRect.height)
                .offset(x: ellipseRect.minX, y: ellipseRect.minY)
                .accessibilityElement()
                .accessibilityLabel("Red circle around line \(mark.lineIndex)")
                .accessibilityIdentifier("interruptEllipse")

            Text(mark.hint)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.red)
                .multilineTextAlignment(.leading)
                .padding(10)
                .frame(width: calloutWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.95)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.red, lineWidth: 2))
                .offset(x: calloutOrigin.x, y: calloutOrigin.y)
                .accessibilityIdentifier("hintText")
        }
    }
}

/// Where a hint callout goes, as plain arithmetic (tested without UI). All rectangles are in zoomed page points.
enum CalloutPlacement {
    static func origin(circle: CGRect, visible: CGRect, size: CGSize, margin: CGFloat = 8, inset: CGFloat = 2) -> CGPoint {
        let area = visible.isNull || visible.isEmpty ? circle.insetBy(dx: -size.width, dy: -size.height) : visible
        let minX = area.minX + inset, maxX = max(minX, area.maxX - size.width - inset)
        let minY = area.minY + inset, maxY = max(minY, area.maxY - size.height - inset)
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, minX), maxX) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, minY), maxY) }
        if circle.maxX + margin + size.width <= area.maxX - inset {
            return CGPoint(x: circle.maxX + margin, y: clampY(circle.midY - size.height / 2))
        }
        if circle.maxY + margin + size.height <= area.maxY - inset {
            return CGPoint(x: clampX(circle.minX), y: circle.maxY + margin)
        }
        return CGPoint(x: clampX(circle.minX), y: clampY(circle.minY - margin - size.height))
    }
}
