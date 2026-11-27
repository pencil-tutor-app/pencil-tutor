import SwiftUI

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
            MathParagraph(parts: problem.promptParts, size: fontSize)
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
