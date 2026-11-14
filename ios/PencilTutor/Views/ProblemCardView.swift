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
    /// Told when the student folds or opens the card (for the session log).
    var onToggle: (Bool) -> Void = { _ in }

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

    /// Remembered between problems and launches: a student who folds the card away keeps the page clear.
    @AppStorage("problemCard.collapsed") private var collapsed = false

    var body: some View {
        Group {
            if collapsed {
                collapsedPill
            } else {
                expandedCard
            }
        }
        .animation(.easeOut(duration: 0.18), value: collapsed)
    }

    /// The whole problem, set the way it is written (stacked fractions), on a see-through card so ink under it still shows.
    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Solve for the letter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 8, rowSpacing: 6) {
                ForEach(pieces) { piece in
                    switch piece {
                    case .word(_, let text):
                        Text(text).font(.system(size: 26, design: .serif))
                    case .fraction(_, let numerator, let denominator):
                        FractionView(numerator: numerator, denominator: denominator)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(problem.promptPlain)
            .accessibilityIdentifier("problemPrompt")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: 460, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { setCollapsed(true) }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Folds the problem away")
    }

    /// One line, plain text: enough to remember the problem while the page gets all the room. Tap to bring the card back.
    private var collapsedPill: some View {
        HStack(spacing: 6) {
            Text(problem.promptPlain)
                .font(.system(size: 17, design: .serif))
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("problemPrompt")
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.thinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .contentShape(Capsule())
        .onTapGesture { setCollapsed(false) }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the whole problem")
    }

    private func setCollapsed(_ value: Bool) {
        collapsed = value
        onToggle(value)
    }
}
