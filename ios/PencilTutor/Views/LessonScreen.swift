import SwiftUI

/// "Learn something new": the lesson panel for the concept the student typed, a bar to ask follow-ups (typed, or tap to talk), and
/// "Your turn", which opens the normal practice page for a problem the server checked. Everything on it is at least 44 pt and
/// nothing times out. The lesson never opens the live voice.
struct LessonScreen: View {
    @StateObject private var lesson: LessonSession
    @EnvironmentObject private var account: StudentAccount
    @Environment(\.dismiss) private var dismiss
    private let env: AppEnvironment
    private let courseTitle: String
    @State private var showPractice = false
    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    init(courseSlug: String, courseTitle: String, concept: String, env: AppEnvironment) {
        self.env = env
        self.courseTitle = courseTitle
        _lesson = StateObject(wrappedValue: LessonSession(courseSlug: courseSlug, concept: concept, env: env))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
        }
        .background(Color(.systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if lesson.phase == .ready { bottomBar }
        }
        .navigationDestination(isPresented: $showPractice) {
            if let problem = lesson.practiceProblem {
                ProblemScreen(problem: problem, env: env, courseTitle: courseTitle, lesson: lesson)
            }
        }
        .onAppear { lesson.start() }
        // Pushing the practice page also hides this screen; only a real exit (Back) ends the lesson.
        .onDisappear { if !showPractice { lesson.stop() } }
        // .contain first: without it this identifier replaces every child's own (CI run 46064329597's hierarchy showed the
        // refusal text and every button all named "lessonScreen"), so nothing inside could be found by its own name.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lessonScreen")
    }

    // MARK: - Top

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: ChromeMetrics.hit, height: ChromeMetrics.hit)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to problems")
            .accessibilityIdentifier("backButton")
            VStack(alignment: .leading, spacing: 2) {
                Text(courseTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(lesson.concept)
                    .font(.system(size: 17, weight: .medium, design: .serif))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("lessonConcept")
            }
            Spacer(minLength: 8)
            AllowanceChip()
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, ChromeMetrics.edge)
        .padding(.top, ChromeMetrics.top)
        .padding(.bottom, 6)
    }

    // MARK: - Body by phase

    @ViewBuilder
    private var content: some View {
        switch lesson.phase {
        case .loading:
            VStack(spacing: 14) {
                ProgressView()
                Text("Putting a lesson together...")
                    .font(.system(size: 20, design: .serif))
                    .accessibilityIdentifier("lessonLoading")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .refused(let message):
            VStack(spacing: 16) {
                Text(message)
                    .font(.system(size: 22, design: .serif))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("lessonRefused")
                bigButton("Pick something else", id: "lessonPickAgainButton") { dismiss() }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 16) {
                Text(message)
                    .font(.system(size: 22, design: .serif))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("lessonFailed")
                bigButton("Try again", id: "lessonRetryButton") { lesson.retryLesson() }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            LessonPanel(lesson: lesson, onClose: nil)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
    }

    private func bigButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .padding(.horizontal, 22)
                .frame(minHeight: ChromeMetrics.hit)
                .background(Capsule().fill(Color.accentColor))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let notice = lesson.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("lessonNotice")
            }
            practiceNotice
            HStack(spacing: 10) {
                micButton
                TextField("Ask a follow-up", text: $typed)
                    .focused($fieldFocused)
                    .submitLabel(.send)
                    .onSubmit(sendTyped)
                    .padding(.horizontal, 14)
                    .frame(minHeight: ChromeMetrics.hit)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .accessibilityIdentifier("lessonFollowupField")
                Button(action: sendTyped) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .frame(width: ChromeMetrics.hit, height: ChromeMetrics.hit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || lesson.isAnswering)
                .accessibilityLabel("Ask")
                .accessibilityIdentifier("lessonAskButton")
                practiceControl
            }
        }
        .padding(.horizontal, ChromeMetrics.edge)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
    }

    private func sendTyped() {
        let text = typed
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !lesson.isAnswering else { return }
        typed = ""
        lesson.ask(typed: text)
    }

    private var micButton: some View {
        Button {
            lesson.tapToTalk()
        } label: {
            Image(systemName: lesson.isRecording ? "waveform" : "mic.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(lesson.isRecording ? Color.white : Color.blue)
                .frame(width: ChromeMetrics.hit, height: ChromeMetrics.hit)
                .background(Circle().fill(lesson.isRecording ? Color.red : Color.blue.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .disabled(account.isBlocked)
        .accessibilityLabel(lesson.isRecording ? "Listening... tap to send" : "Tap to ask")
        .accessibilityIdentifier("lessonMicButton")
    }

    @ViewBuilder
    private var practiceNotice: some View {
        switch lesson.practiceState {
        case .notChecked:
            Text("I couldn't make a practice problem I'm sure of. Try again?")
                .font(.callout)
                .accessibilityIdentifier("lessonPracticeNotChecked")
        case .failed(let message):
            Text(message)
                .font(.callout)
                .accessibilityIdentifier("lessonPracticeFailed")
        case .preparing, .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private var practiceControl: some View {
        switch lesson.practiceState {
        case .ready:
            Button {
                guard lesson.canStartPractice else { return }
                lesson.practiceStarted()
                showPractice = true
            } label: {
                Label("Your turn", systemImage: "pencil.tip")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 16)
                    .frame(minHeight: ChromeMetrics.hit)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("lessonYourTurnButton")
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Getting a problem ready...")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 16)
            .frame(minHeight: ChromeMetrics.hit)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("lessonPracticePreparing")
        case .notChecked, .failed:
            Button {
                lesson.tryPracticeAgain()
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 16)
                    .frame(minHeight: ChromeMetrics.hit)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("lessonTryAgainButton")
        }
    }
}
