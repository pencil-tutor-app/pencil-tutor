import SwiftUI

// Typesetting for problem statements (see `MathMarkup` for what is recognised). Everything here is plain SwiftUI: Text with
// baseline offsets for exponents and indices, and three small drawn pieces (a stacked fraction, a root with its overbar, a
// matrix with brackets). No web view, no font download, nothing that needs the network.

/// A list of math nodes set on one baseline: letters and exponents in one run of text, with roots, matrices and Σ-with-bounds as
/// separate pieces beside it. Never wraps or truncates; the caller decides where a line breaks (`MathMarkup.words`).
struct MathRunView: View {
    let nodes: [MathNode]
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(Self.segments(nodes).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .inline(let inline):
                    Text(Self.attributed(inline, size: size))
                case .block(let node):
                    block(node)
                }
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func block(_ node: MathNode) -> some View {
        switch node {
        case .root(let index, let content):
            RadicalView(index: index, content: content, size: size)
        case .matrix(let rows):
            MatrixView(rows: rows, size: size)
        case .limits(let symbol, let lower, let upper):
            LimitsView(symbol: symbol, lower: lower, upper: upper, size: size)
        default:
            EmptyView()
        }
    }

    enum Segment {
        case inline([MathNode])
        case block(MathNode)
    }

    /// Text, exponents and indices run together in one `Text`; each root, matrix or Σ is its own piece.
    static func segments(_ nodes: [MathNode]) -> [Segment] {
        var result: [Segment] = []
        var run: [MathNode] = []
        for node in nodes {
            switch node {
            case .text, .sup, .sub:
                run.append(node)
            case .root, .matrix, .limits:
                if !run.isEmpty { result.append(.inline(run)); run = [] }
                result.append(.block(node))
            }
        }
        if !run.isEmpty { result.append(.inline(run)) }
        return result
    }

    /// One piece of styled text: exponents and indices are smaller and sit higher or lower on the baseline. Anything that cannot
    /// be drawn inside a line of text (a root, a matrix) is written out as plain characters, which is what the collapsed pill and
    /// the problem list want.
    static func attributed(_ nodes: [MathNode], size: CGFloat, level: Int = 0, baseline: CGFloat = 0) -> AttributedString {
        let ownSize = size * MathMarkup.scriptStyle(level: level, raised: true).scale
        var out = AttributedString()
        for node in nodes {
            switch node {
            case .text(let string):
                out += styled(string, size: ownSize, baseline: baseline)
            case .sup(let inner):
                let style = MathMarkup.scriptStyle(level: level + 1, raised: true)
                out += attributed(inner, size: size, level: level + 1, baseline: baseline + ownSize * style.shift)
            case .sub(let inner):
                let style = MathMarkup.scriptStyle(level: level + 1, raised: false)
                out += attributed(inner, size: size, level: level + 1, baseline: baseline + ownSize * style.shift)
            case .root, .matrix, .limits:
                out += styled(MathMarkup.plainText([node]), size: ownSize, baseline: baseline)
            }
        }
        return out
    }

    private static func styled(_ string: String, size: CGFloat, baseline: CGFloat) -> AttributedString {
        var run = AttributedString(string)
        run.font = .system(size: size, design: .serif)
        if baseline != 0 { run.baselineOffset = baseline }
        return run
    }
}

/// One line of a prompt as styled text (exponents raised, roots and matrices as characters). For the collapsed pill and the
/// problem list, which show a single line and must not need the full layout.
enum MathLine {
    static func text(_ source: String, size: CGFloat) -> Text {
        Text(MathRunView.attributed(MathMarkup.parse(source), size: size))
    }
}

// MARK: - Stacked fraction

/// A fraction drawn the way it is written: numerator, bar, denominator. Its baseline is the middle of the bar plus the height of
/// the maths axis, so the words around it line up with the bar like they do on paper.
struct FractionView: View {
    let numerator: [MathNode]
    let denominator: [MathNode]
    /// Point size of the numerals; the card shrinks it for a long prompt.
    var size: CGFloat = 30
    /// Spoken by VoiceOver, e.g. "1 over 3".
    var spoken: String?

    var body: some View {
        StackedLayout(spacing: 3, baseline: .axisOfSubview(1, above: size * 0.3), stretched: 1) {
            MathRunView(nodes: numerator, size: size).padding(.horizontal, 3)
            Rectangle().frame(height: 1.6)
            MathRunView(nodes: denominator, size: size).padding(.horizontal, 3)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken ?? "\(MathMarkup.plainText(numerator)) over \(MathMarkup.plainText(denominator))")
    }
}

/// Subviews in a column, each centred, the one at `baseline` giving the row's baseline. One subview (`stretched`) fills the
/// column's width (the fraction bar). Used for fractions and for a Σ with its bounds.
struct StackedLayout: Layout {
    enum Baseline {
        /// The first text baseline of this subview.
        case ofSubview(Int)
        /// The vertical middle of this subview, plus `above` points: the height of the maths axis over the baseline.
        case axisOfSubview(Int, above: CGFloat)
    }

    var spacing: CGFloat
    var baseline: Baseline
    /// The subview that is as wide as the whole column (the fraction bar). Nil for none.
    var stretched: Int?

    private func frames(_ subviews: Subviews, width proposedWidth: CGFloat?) -> (frames: [CGRect], size: CGSize) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposedWidth ?? sizes.map { $0.width }.max() ?? 0
        var y: CGFloat = 0
        var result: [CGRect] = []
        for size in sizes {
            result.append(CGRect(x: (width - size.width) / 2, y: y, width: size.width, height: size.height))
            y += size.height + spacing
        }
        return (result, CGSize(width: width, height: max(0, y - spacing)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return frames(subviews, width: widest).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laidOut = frames(subviews, width: bounds.width)
        for (index, frame) in laidOut.frames.enumerated() {
            let place = index == stretched ? CGRect(x: 0, y: frame.minY, width: bounds.width, height: frame.height) : frame
            subviews[index].place(at: CGPoint(x: bounds.minX + place.minX, y: bounds.minY + place.minY), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: place.width, height: place.height))
        }
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                           cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline || guide == .lastTextBaseline else { return nil }
        let laidOut = frames(subviews, width: bounds.width)
        switch baseline {
        case .ofSubview(let index):
            guard laidOut.frames.indices.contains(index) else { return nil }
            return laidOut.frames[index].minY + subviews[index].dimensions(in: .unspecified)[.firstTextBaseline]
        case .axisOfSubview(let index, let above):
            guard laidOut.frames.indices.contains(index) else { return nil }
            return laidOut.frames[index].midY + above
        }
    }
}

// MARK: - Σ with bounds

struct LimitsView: View {
    let symbol: String
    let lower: [MathNode]
    let upper: [MathNode]
    let size: CGFloat

    var body: some View {
        StackedLayout(spacing: 1, baseline: .ofSubview(1), stretched: nil) {
            MathRunView(nodes: upper.isEmpty ? [.text(" ")] : upper, size: size * 0.7)
            Text(symbol).font(.system(size: size * 1.3, design: .serif))
            MathRunView(nodes: lower.isEmpty ? [.text(" ")] : lower, size: size * 0.7)
        }
        .fixedSize()
        .padding(.horizontal, 2)
    }
}

// MARK: - Roots

/// A root sign with its overbar over the content, drawn as one line so it stays crisp at any size.
struct RadicalView: View {
    let index: Int?
    let content: [MathNode]
    let size: CGFloat

    var body: some View {
        let lead = size * 0.7
        MathRunView(nodes: content, size: size)
            .padding(.leading, lead)
            .padding(.trailing, size * 0.1)
            .padding(.top, size * 0.16)
            .background(alignment: .topLeading) {
                RadicalShape(lead: lead)
                    .stroke(style: StrokeStyle(lineWidth: max(1.2, size * 0.055), lineCap: .round, lineJoin: .round))
            }
            .overlay(alignment: .topLeading) {
                if let index {
                    Text("\(index)")
                        .font(.system(size: size * 0.45, design: .serif))
                        .offset(x: size * 0.02, y: size * 0.18)
                }
            }
            .padding(.leading, 1)
    }
}

/// The tick, the long stroke down, the stroke up and the overbar. `lead` is the width of the sign before the overbar starts.
struct RadicalShape: Shape {
    let lead: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = rect.minY + 1
        path.move(to: CGPoint(x: rect.minX + 0.04 * lead, y: rect.minY + 0.62 * rect.height))
        path.addLine(to: CGPoint(x: rect.minX + 0.26 * lead, y: rect.minY + 0.54 * rect.height))
        path.addLine(to: CGPoint(x: rect.minX + 0.58 * lead, y: rect.maxY - 1))
        path.addLine(to: CGPoint(x: rect.minX + lead, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: top))
        return path
    }
}

// MARK: - Matrices

/// Rows of cells in a grid, between tall brackets. The middle of the matrix lines up with the middle of the text beside it.
struct MatrixView: View {
    let rows: [[[MathNode]]]
    let size: CGFloat

    var body: some View {
        Grid(horizontalSpacing: size * 0.6, verticalSpacing: size * 0.18) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        MathRunView(nodes: cell, size: size)
                    }
                }
            }
        }
        .padding(.horizontal, size * 0.5)
        .padding(.vertical, size * 0.1)
        .background(alignment: .leading) { BracketShape(side: .leading).stroke(lineWidth: 1.4).frame(width: size * 0.28) }
        .background(alignment: .trailing) { BracketShape(side: .trailing).stroke(lineWidth: 1.4).frame(width: size * 0.28) }
        .padding(.horizontal, 2)
        .alignmentGuide(.firstTextBaseline) { d in d.height / 2 + size * 0.3 }
        .fixedSize()
    }
}

struct BracketShape: Shape {
    let side: HorizontalEdge

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = side == .leading ? rect.minX + 1 : rect.maxX - 1
        let tip = side == .leading ? rect.maxX : rect.minX
        path.move(to: CGPoint(x: tip, y: rect.minY + 1))
        path.addLine(to: CGPoint(x: x, y: rect.minY + 1))
        path.addLine(to: CGPoint(x: x, y: rect.maxY - 1))
        path.addLine(to: CGPoint(x: tip, y: rect.maxY - 1))
        return path
    }
}
