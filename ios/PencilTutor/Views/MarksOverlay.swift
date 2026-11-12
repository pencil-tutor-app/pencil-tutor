import SwiftUI

/// The tutor's marks, drawn above the canvas and separate from the student's ink.
/// Touches pass straight through to the canvas underneath.
struct MarksOverlay: View {
    let marks: [Mark]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(marks) { mark in
                    MarkView(mark: mark, canvasSize: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }
}

private struct MarkView: View {
    let mark: Mark
    let canvasSize: CGSize

    private let calloutWidth: CGFloat = 260
    private let calloutHeight: CGFloat = 64

    private var ellipseRect: CGRect {
        let padded = mark.box.insetBy(dx: -22, dy: -14)
        let clippedMinX = max(2, padded.minX)
        let clippedMinY = max(2, padded.minY)
        let clippedMaxX = min(canvasSize.width - 2, padded.maxX)
        let clippedMaxY = min(canvasSize.height - 2, padded.maxY)
        return CGRect(x: clippedMinX, y: clippedMinY,
                      width: max(20, clippedMaxX - clippedMinX), height: max(20, clippedMaxY - clippedMinY))
    }

    private var calloutOrigin: CGPoint {
        let rect = ellipseRect
        let margin: CGFloat = 8
        if rect.maxX + margin + calloutWidth <= canvasSize.width {
            return CGPoint(x: rect.maxX + margin, y: max(2, rect.midY - calloutHeight / 2))
        }
        if rect.maxY + margin + calloutHeight <= canvasSize.height {
            return CGPoint(x: min(max(2, rect.minX), canvasSize.width - calloutWidth - 2), y: rect.maxY + margin)
        }
        return CGPoint(x: min(max(2, rect.minX), canvasSize.width - calloutWidth - 2),
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
