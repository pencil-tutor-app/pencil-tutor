import SwiftUI

/// The worked solution of the problem on the page, as a 360 pt panel on the right under the action pill. It is built from the lesson
/// panel's parts (`MathParagraph`, the 360 pt frame, the 44 pt close button) and does not use `LessonSession`. It stays until its close
/// button is tapped. It says what state it is in: working it out, the steps, "I couldn't work this one out with confidence", or a
/// failed request; and under the steps, Try one like it.
struct ShowMeSidePanel: View {
    @ObservedObject var showMe: ShowMeSession
    /// The statement as the problem card draws it (fractions stay stacked).
    let statement: [PromptPart]
    /// Try again, from the not-checked and failed states. It goes through the screen's session so the voice is told once the steps show.
    let onRetry: () -> Void

    var body: some View {
        if showMe.isOpen {
            ShowMePanel(showMe: showMe, statement: statement, onClose: { showMe.close() }, onRetry: onRetry, bodySize: 17)
                .frame(width: 360)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                .padding(.top, ChromeMetrics.top + ChromeMetrics.hit + ChromeMetrics.gap)
                .padding(.trailing, ChromeMetrics.edge)
                .padding(.bottom, ChromeMetrics.edge)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("showMeSidePanel")
        }
    }
}

struct ShowMePanel: View {
    @ObservedObject var showMe: ShowMeSession
    let statement: [PromptPart]
    var onClose: () -> Void = {}
    var onRetry: () -> Void = {}
    var bodySize: CGFloat = 17

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("showMePanel")
    }

    private var header: some View {
        HStack {
            Text("Show me how")
                .font(.headline)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: ChromeMetrics.hit, height: ChromeMetrics.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("showMeCloseButton")
        }
        .padding(.leading, 20)
        .padding(.trailing, 4)
    }

    @ViewBuilder
    private var content: some View {
        switch showMe.phase {
        case .closed:
            EmptyView()
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Working it out...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("showMeLoading")
        case .shown(let solution):
            MathParagraph(parts: statement, size: bodySize + 2)
            Divider()
            ForEach(Array(solution.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: bodySize - 4, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .trailing)
                    MathParagraph(plain: step, size: bodySize)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(index + 1). \(step)")
                .accessibilityIdentifier("showMeStep-\(index + 1)")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Answer")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                MathParagraph(plain: solution.finalAnswer, size: bodySize + 2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("showMeAnswer")
        case .notChecked:
            Text("I couldn't work this one out with confidence. Try again?")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("showMeNotChecked")
            capsuleButton("Try again", symbol: "arrow.clockwise", id: "showMeRetryButton", action: onRetry)
        case .failed(let message):
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("showMeFailed")
            capsuleButton("Try again", symbol: "arrow.clockwise", id: "showMeRetryButton", action: onRetry)
        }
    }

    /// Try one like it, at the bottom of the panel once the steps are showing.
    @ViewBuilder
    private var footer: some View {
        if case .shown = showMe.phase {
            VStack(alignment: .leading, spacing: 8) {
                switch showMe.next {
                case .idle, .preparing:
                    EmptyView()
                case .notChecked:
                    Text("I couldn't make a problem I'm sure of. Try again?")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("showMeLikeNotChecked")
                case .failed(let message):
                    Text(message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("showMeLikeFailed")
                }
                Button {
                    showMe.tryOneLikeIt()
                } label: {
                    HStack(spacing: 8) {
                        if showMe.next == .preparing {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "pencil.tip")
                        }
                        Text(showMe.next == .preparing ? "Getting one ready..." : "Try one like it")
                    }
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: ChromeMetrics.hit)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(showMe.next == .preparing)
                .accessibilityIdentifier("tryOneLikeItButton")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func capsuleButton(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 16)
                .frame(minHeight: ChromeMetrics.hit)
                .background(Capsule().fill(Color.accentColor))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
