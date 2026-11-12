import SwiftUI

/// A stacked fraction drawn natively: numerator, bar, denominator. No web view.
struct FractionView: View {
    let numerator: String
    let denominator: String

    var body: some View {
        VStack(spacing: 3) {
            Text(numerator)
                .padding(.horizontal, 3)
            Rectangle()
                .frame(height: 2)
            Text(denominator)
                .padding(.horizontal, 3)
        }
        .font(.system(size: 30, design: .serif))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(numerator) over \(denominator)")
    }
}

/// Lays children out left to right and wraps to a new row when the width runs out. Each row is centred vertically,
/// so the middle of a fraction (its bar) lines up with the middle of the text beside it.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 12

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var rows: [[Int]] = [[]]
        var rowWidth: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            let needed = rows[rows.count - 1].isEmpty ? size.width : rowWidth + spacing + size.width
            if needed > width && !rows[rows.count - 1].isEmpty {
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
            let rowHeight = row.map { sizes[$0].height }.max() ?? 0
            var x: CGFloat = 0
            for index in row {
                let size = sizes[index]
                frames[index] = CGRect(x: x, y: y + (rowHeight - size.height) / 2, width: size.width, height: size.height)
                x += size.width + spacing
            }
            widest = max(widest, x - spacing)
            y += rowHeight + rowSpacing
        }
        return (frames, CGSize(width: widest, height: max(0, y - rowSpacing)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
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

/// The problem at the top of the screen.
struct ProblemCardView: View {
    let problem: Problem

    private enum Piece: Identifiable {
        case word(id: Int, text: String)
        case fraction(id: Int, numerator: String, denominator: String)

        var id: Int {
            switch self {
            case .word(let id, _): return id
            case .fraction(let id, _, _): return id
            }
        }
    }

    private var pieces: [Piece] {
        var result: [Piece] = []
        for part in problem.promptParts {
            switch part {
            case .text(let text):
                for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
                    result.append(.word(id: result.count, text: String(word)))
                }
            case .fraction(let numerator, let denominator):
                result.append(.fraction(id: result.count, numerator: numerator, denominator: denominator))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Solve for the letter")
                .font(.footnote)
                .foregroundStyle(.secondary)
            FlowLayout {
                ForEach(pieces) { piece in
                    switch piece {
                    case .word(_, let text):
                        Text(text).font(.system(size: 30, design: .serif))
                    case .fraction(_, let numerator, let denominator):
                        FractionView(numerator: numerator, denominator: denominator)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(problem.promptPlain)
            .accessibilityIdentifier("problemPrompt")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(white: 0.96))
    }
}
