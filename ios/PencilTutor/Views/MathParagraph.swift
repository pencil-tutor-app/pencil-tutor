import SwiftUI

/// Lays children out left to right and wraps to a new row when the width runs out. Children sit on a shared text baseline in each
/// row, so a stacked fraction (whose baseline is the middle of its bar), a root, a matrix and plain words all line up as they
/// would on paper.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 12

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let baselines = subviews.map { $0.dimensions(in: .unspecified)[.firstTextBaseline] }
        var rows: [[Int]] = [[]]
        var rowWidth: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            let needed = rows[rows.count - 1].isEmpty ? size.width : rowWidth + spacing + size.width
            // A hair of tolerance: a row that just fits when the height is measured must still fit when it is placed.
            if needed > width + 0.5 && !rows[rows.count - 1].isEmpty {
                rows.append([index])
                rowWidth = size.width
            } else {
                rows[rows.count - 1].append(index)
                rowWidth = needed
            }
        }
        var frames = [CGRect](repeating: .zero, count: sizes.count)
        var y: CGFloat = 0
        var widest: CGFloat = 0
        for row in rows where !row.isEmpty {
            let above = row.map { baselines[$0] }.max() ?? 0
            let below = row.map { sizes[$0].height - baselines[$0] }.max() ?? 0
            var x: CGFloat = 0
            for index in row {
                frames[index] = CGRect(x: x, y: y + above - baselines[index], width: sizes[index].width, height: sizes[index].height)
                x += sizes[index].width + spacing
            }
            widest = max(widest, x - spacing)
            y += above + below + rowSpacing
        }
        return (frames, CGSize(width: widest, height: max(0, y - rowSpacing)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        // Report the width that was offered (not just the widest row), so the rows break in the same places when placed.
        if let offered = proposal.width, offered.isFinite { return CGSize(width: offered, height: result.size.height) }
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }
}

/// A paragraph of maths set the way it is written: words and stacked fractions flowing left to right and wrapping at the width
/// offered. The text of each part is read by `MathMarkup`, so `x^(1/3)` is an exponent, `√(2x + 1)` a root with its overbar and
/// `[1 2; 3 4]` a matrix. The problem card, the lesson panel and the practice problem all draw through this one view, so a
/// statement looks the same wherever it appears. A plain sentence is `[.text(sentence)]`.
struct MathParagraph: View {
    let parts: [PromptPart]
    let size: CGFloat

    init(parts: [PromptPart], size: CGFloat) {
        self.parts = parts
        self.size = size
    }

    init(plain: String, size: CGFloat) {
        self.init(parts: [.text(plain)], size: size)
    }

    enum Piece: Identifiable {
        /// Part of a sentence or equation up to the next space: letters, exponents, a root or a matrix.
        case word(id: Int, nodes: [MathNode])
        case fraction(id: Int, numerator: [MathNode], denominator: [MathNode])

        var id: Int {
            switch self {
            case .word(let id, _): return id
            case .fraction(let id, _, _): return id
            }
        }
    }

    var body: some View {
        FlowLayout(spacing: size * 0.3, rowSpacing: size * 0.3) {
            ForEach(Self.pieces(of: parts)) { piece in
                switch piece {
                case .word(_, let nodes):
                    MathRunView(nodes: nodes, size: size)
                case .fraction(_, let numerator, let denominator):
                    FractionView(numerator: numerator, denominator: denominator, size: size * 1.1)
                }
            }
        }
    }

    /// The parts cut into words and stacked fractions (one piece each), in reading order.
    static func pieces(of parts: [PromptPart]) -> [Piece] {
        var result: [Piece] = []
        for part in parts {
            switch part {
            case .text(let text):
                for word in MathMarkup.words(MathMarkup.parse(text)) {
                    result.append(.word(id: result.count, nodes: word))
                }
            case .fraction(let numerator, let denominator):
                result.append(.fraction(id: result.count, numerator: MathMarkup.parse(numerator), denominator: MathMarkup.parse(denominator)))
            }
        }
        return result
    }
}
