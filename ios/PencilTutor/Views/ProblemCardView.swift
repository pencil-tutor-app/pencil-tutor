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

/// How big the words of a prompt are drawn.
enum PromptLayout {
    /// Point size by prompt length: a short equation is big; a 260 character word problem is 18 so it fits in about six lines.
    static func fontSize(forLength length: Int) -> CGFloat {
        switch length {
        case ..<61: return 26
        case ..<111: return 23
        case ..<171: return 20
        default: return 18
        }
    }
}

/// The problem at the top of the screen.
struct ProblemCardView: View {
    let problem: Problem
    /// Small line above the problem, the course name ("BC Math 5"). Nil leaves it out.
    var heading: String? = nil
    /// Told when the student folds or opens the card (for the session log).
    var onToggle: (Bool) -> Void = { _ in }

    private var fontSize: CGFloat { PromptLayout.fontSize(forLength: problem.promptPlain.count) }

    private enum Piece: Identifiable {
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

    /// The prompt cut into words and stacked fractions. The text of each part is read as math (`MathMarkup`), so `x^(1/3)` is an
    /// exponent, `√(2x + 1)` a root with its overbar and `[1 2; 3 4]` a matrix.
    private var pieces: [Piece] {
        var result: [Piece] = []
        for part in problem.promptParts {
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

    /// The whole problem, set the way it is written (stacked fractions, raised exponents), on a see-through card so ink under it
    /// still shows.
    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let heading {
                    Text(heading)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)   // wraps to its words, never cut off
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("problemCourseTitle")
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            FlowLayout(spacing: fontSize * 0.3, rowSpacing: fontSize * 0.3) {
                ForEach(pieces) { piece in
                    switch piece {
                    case .word(_, let nodes):
                        MathRunView(nodes: nodes, size: fontSize)
                    case .fraction(_, let numerator, let denominator):
                        FractionView(numerator: numerator, denominator: denominator, size: fontSize * 1.1)
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

    /// One line, exponents raised: enough to remember the problem while the page gets all the room. Tap to bring the card back.
    /// A prompt too long for the pill is never cut off with an ellipsis: the pill says "Problem" instead, and the tap still
    /// opens the whole card. Same 44 pt height as the Back button.
    private var collapsedPill: some View {
        HStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                MathLine.text(problem.promptPlain, size: 17)
                    .lineLimit(1)
                    .fixedSize()
                Text("Problem")
                    .font(.system(size: 17, design: .serif))
                    .lineLimit(1)
                    .fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(problem.promptPlain)
            .accessibilityIdentifier("problemPrompt")
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
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
