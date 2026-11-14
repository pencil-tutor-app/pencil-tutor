import SwiftUI

/// The tutor's marks, drawn above the canvas and separate from the student's ink.
/// Touches pass straight through to the canvas underneath.
///
/// The page scrolls and zooms, the overlay does not: a mark's box is in page points (the same numbers as the ink and the line
/// boxes), so it is multiplied by the zoom and the whole layer is shifted up and left by the canvas's scroll offset
/// (`screen = page * zoom - offset`), which keeps a circle on its line while the page moves or is pinched. Only the circle
/// scales; the callout keeps its reading size at any zoom. The overlay's own frame is the visible canvas, so anything scrolled
/// off screen is clipped. The callout is placed against the whole (zoomed) page, not against the screen, so a mark far out on
/// the page keeps its callout beside or under it instead of being squeezed back into the first screen.
struct MarksOverlay: View {
    let marks: [Mark]
    @ObservedObject var viewport: CanvasViewport

    var body: some View {
        GeometryReader { proxy in
            let pageSize = CGSize(width: max(proxy.size.width, viewport.contentSize.width),
                                  height: max(proxy.size.height, viewport.contentSize.height))
            ZStack(alignment: .topLeading) {
                ForEach(marks) { mark in
                    MarkView(mark: mark, zoom: viewport.zoomScale, pageSize: pageSize)
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

    private var calloutOrigin: CGPoint {
        let rect = ellipseRect
        let margin: CGFloat = 8
        if rect.maxX + margin + calloutWidth <= pageSize.width {
            return CGPoint(x: rect.maxX + margin, y: max(2, rect.midY - calloutHeight / 2))
        }
        if rect.maxY + margin + calloutHeight <= pageSize.height {
            return CGPoint(x: min(max(2, rect.minX), pageSize.width - calloutWidth - 2), y: rect.maxY + margin)
        }
        return CGPoint(x: min(max(2, rect.minX), pageSize.width - calloutWidth - 2),
                       y: max(2, rect.minY - margin - calloutHeight))
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
