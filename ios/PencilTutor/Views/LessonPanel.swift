import SwiftUI

/// The lesson as it stays on screen: title, the steps, the worked example and the conversation so far. It is set in type by
/// `MathParagraph`, the same view the problem card uses (never drawn as ink), and nothing on it times out. On the lesson screen it
/// fills the page; on the practice page it is a 360 pt side panel that stays until its close button (44 pt) is tapped.
///
/// The example is read through `LessonSession.visibleExample` only: while its check is pending the slot says "Checking the
/// example...", and if the check rejected it the slot is empty (nothing about it is shown, so an unchecked example never flashes).
struct LessonPanel: View {
    @ObservedObject var lesson: LessonSession
    /// Nil on the lesson screen (the Back button leaves); the side panel passes its close action.
    var onClose: (() -> Void)?
    var bodySize: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onClose {
                header(onClose: onClose)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        LessonPanelContent(lesson: lesson, bodySize: bodySize)
                        Color.clear.frame(height: 1).id("lessonEnd")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: lesson.turns.count) { _, _ in
                    withAnimation { proxy.scrollTo("lessonEnd", anchor: .bottom) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lessonPanel")
    }

    private func header(onClose: @escaping () -> Void) -> some View {
        HStack {
            Text("Lesson")
                .font(.headline)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: ChromeMetrics.hit, height: ChromeMetrics.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close lesson")
            .accessibilityIdentifier("lessonCloseButton")
        }
        .padding(.leading, 20)
        .padding(.trailing, 4)
    }

}

/// What the panel says, without its scrolling and close button: the title, the steps, the example slot and the conversation.
struct LessonPanelContent: View {
    @ObservedObject var lesson: LessonSession
    var bodySize: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let body = lesson.lesson {
            Text(body.title)
                .font(.system(size: bodySize + 8, weight: .semibold, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("lessonTitle")
            ForEach(Array(body.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: bodySize - 4, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .trailing)
                    MathParagraph(plain: step, size: bodySize)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(index + 1). \(step)")
                .accessibilityIdentifier("lessonStep-\(index + 1)")
            }
            exampleSlot
            if !lesson.turns.isEmpty {
                Divider()
                ForEach(lesson.turns) { turn in
                    turnRow(turn)
                }
            }
        }
    }

    @ViewBuilder
    private var exampleSlot: some View {
        switch lesson.exampleState {
        case .pending:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking the example...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("lessonExamplePending")
        case .notChecked:
            Text("I couldn't check the example yet, so I'm leaving it out.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("lessonExampleNotChecked")
        case .withheld:
            EmptyView()
        case .checked:
            if let example = lesson.visibleExample {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Example")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    MathParagraph(plain: example.promptPlain, size: bodySize + 2)
                    ForEach(Array(example.steps.enumerated()), id: \.offset) { _, line in
                        MathParagraph(plain: line, size: bodySize)
                    }
                    MathParagraph(plain: example.finalAnswer, size: bodySize + 2)
                        .padding(.top, 2)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("lessonExample")
            }
        }
    }

    private func turnRow(_ turn: LessonTurn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(turn.role == .student ? "You" : "Tutor")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            MathParagraph(plain: turn.text, size: bodySize - 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(turn.role == .student ? "You" : "Tutor"): \(turn.text)")
        .accessibilityIdentifier("lessonTurn-\(turn.role.rawValue)")
    }
}
