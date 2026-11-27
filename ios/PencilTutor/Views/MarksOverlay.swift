import SwiftUI

/// The tutor's marks, drawn above the canvas and separate from the student's ink.
/// Touches pass straight through to the canvas underneath, except on each callout's "Not a mistake" button: that button is the
/// only thing here that takes a touch (the circle, the hint words and the callout's card are all switched off for hit testing, so
/// ink written, scrolled or pinched right next to the button, or under the card, still reaches the canvas).
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
    /// The student tapped "Not a mistake" on this mark's callout.
    var onNotAMistake: (UUID) -> Void = { _ in }

    var body: some View {
        GeometryReader { proxy in
            let pageSize = CGSize(width: max(proxy.size.width, viewport.contentSize.width),
                                  height: max(proxy.size.height, viewport.contentSize.height))
            ZStack(alignment: .topLeading) {
                ForEach(marks) { mark in
                    MarkView(mark: mark, zoom: viewport.zoomScale, pageSize: pageSize,
                             visible: CGRect(origin: viewport.offset, size: proxy.size),
                             bottomKeepOut: max(proxy.safeAreaInsets.bottom, MarkView.homeIndicatorKeepOut),
                             onNotAMistake: onNotAMistake)
                }
            }
            .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
            .offset(x: -viewport.offset.x, y: -viewport.offset.y)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .clipped()
    }
}

private struct MarkView: View {
    let mark: Mark
    let zoom: CGFloat
    /// The whole page in screen points (zoomed).
    let pageSize: CGSize
    /// The part of the (zoomed) page on screen, in the same points as `pageSize`.
    let visible: CGRect
    /// How far the callout stays above the bottom edge of the screen, so its button is not under the home-indicator swipe zone.
    let bottomKeepOut: CGFloat
    let onNotAMistake: (UUID) -> Void

    /// At least this far above the bottom edge even where the system reports no inset (a stage-managed window).
    static let homeIndicatorKeepOut: CGFloat = 24
    /// The button's height: Apple's minimum tap target.
    static let buttonHeight: CGFloat = 44

    private let calloutWidth: CGFloat = 260
    /// Until the callout has been measured: two lines of hint, the gap, the 44 pt button and the padding. The real height (a hint of
    /// one to four lines) replaces it as soon as the callout is laid out, so placement never trusts a fixed number for long.
    @State private var calloutHeight: CGFloat = 10 + 48 + 8 + MarkView.buttonHeight + 10

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
        var area = visible.intersection(CGRect(origin: .zero, size: pageSize))
        if !area.isNull { area.size.height = max(0, area.height - bottomKeepOut) }
        return CalloutPlacement.origin(circle: ellipseRect, visible: area, size: CGSize(width: calloutWidth, height: calloutHeight))
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
                .allowsHitTesting(false)

            callout
                .offset(x: calloutOrigin.x, y: calloutOrigin.y)
        }
    }

    /// The hint and, under it, the "Not a mistake" button. Only the button takes touches: the words, the card behind them and
    /// its outline do not, so a pen stroke that starts on them still draws.
    private var callout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mark.hint)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.red)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("hintText")
                .allowsHitTesting(false)
            Button {
                onNotAMistake(mark.id)
            } label: {
                Text("Not a mistake")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity, minHeight: Self.buttonHeight)
                    .background(Capsule().fill(Color.red.opacity(0.10)))
                    .overlay(Capsule().stroke(Color.red.opacity(0.6), lineWidth: 1.5))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Not a mistake on line \(mark.lineIndex)")
            .accessibilityIdentifier("notAMistakeButton")
        }
        .padding(10)
        .frame(width: calloutWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.95)).allowsHitTesting(false))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.red, lineWidth: 2).allowsHitTesting(false))
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: CalloutHeightKey.self, value: geometry.size.height)
            }
            .allowsHitTesting(false)
        }
        .onPreferenceChange(CalloutHeightKey.self) { measured in
            if measured > 0, abs(measured - calloutHeight) > 0.5 { calloutHeight = measured }
        }
    }
}

private struct CalloutHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
