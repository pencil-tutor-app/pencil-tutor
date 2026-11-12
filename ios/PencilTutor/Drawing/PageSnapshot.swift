import PencilKit
import UIKit

/// A downscaled picture of the page for the tutor.
struct PageSnapshot {
    let png: Data
    let pixelWidth: Int
    let pixelHeight: Int
    /// Pixels per canvas point. Multiply canvas coordinates by this to get image coordinates.
    let scale: CGFloat
}

enum PageSnapshotter {
    /// Longest side of the image in pixels (plan amendment 5).
    static let maxLongSide: CGFloat = 1024
    /// Largest PNG we will send (plan amendment 5).
    static let maxBytes = 400_000

    /// Renders the ink on white with faint line numbers in the left margin.
    /// If the PNG is over the size limit, the picture is shrunk a little at a time; it never grows past 1024 px.
    static func make(drawing: PKDrawing, canvasSize: CGSize, lines: [InkLine]) throws -> PageSnapshot {
        guard canvasSize.width > 1, canvasSize.height > 1 else {
            throw TutorError.snapshotFailed(detail: "canvas has no size (\(Int(canvasSize.width))x\(Int(canvasSize.height)))")
        }
        let startScale = min(1, maxLongSide / max(canvasSize.width, canvasSize.height))
        var scale = startScale
        for _ in 0..<6 {
            let snapshot = render(drawing: drawing, canvasSize: canvasSize, lines: lines, scale: scale)
            if snapshot.png.count <= maxBytes { return snapshot }
            scale *= 0.8
        }
        throw TutorError.snapshotFailed(detail: "page image stayed over \(maxBytes) bytes after shrinking")
    }

    private static func render(drawing: PKDrawing, canvasSize: CGSize, lines: [InkLine], scale: CGFloat) -> PageSnapshot {
        let pixelSize = CGSize(width: max(1, (canvasSize.width * scale).rounded()),
                               height: max(1, (canvasSize.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)

        var inkImage = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            inkImage = drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: scale)
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
            for line in lines {
                let label = "\(line.index)" as NSString
                let labelSize = label.size(withAttributes: numberAttributes)
                let x: CGFloat = line.isSideCalculation
                    ? max(2, line.box.minX * scale - labelSize.width - 4)
                    : 4
                let y = max(0, line.box.midY * scale - labelSize.height / 2)
                label.draw(at: CGPoint(x: x, y: y), withAttributes: numberAttributes)
            }
        }
        return PageSnapshot(png: png, pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height), scale: scale)
    }
}

extension LineWire {
    /// Converts a line from canvas points to the snapshot's pixel space.
    init(_ line: InkLine, scale: CGFloat) {
        self.init(
            index: line.index,
            box: BoxWire(
                x: Double(line.box.minX * scale),
                y: Double(line.box.minY * scale),
                w: Double(line.box.width * scale),
                h: Double(line.box.height * scale)
            ),
            lastStrokeAt: TimeText.iso(line.lastStrokeAt)
        )
    }
}
