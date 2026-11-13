import SwiftUI

struct ProblemScreen: View {
    @StateObject private var session: TutorSession

    init(problem: Problem, env: AppEnvironment) {
        _session = StateObject(wrappedValue: TutorSession(problem: problem, env: env))
    }

    var body: some View {
        VStack(spacing: 0) {
            ProblemCardView(problem: session.problem)
            Divider()
            // Buttons sit above the page: the floating Pencil tool picker covers the bottom of the screen.
            controlBar
            Divider()
            // Messages sit at the top of the page: the floating Pencil tool picker covers the bottom.
            ZStack(alignment: .top) {
                InkCanvas(session: session)
                MarksOverlay(marks: session.marks)
                if let message = session.statusMessage {
                    Text(message)
                        .font(.system(size: 20, weight: .medium))
                        .padding(14)
                        .frame(maxWidth: 560, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.12, opacity: 0.92)))
                        .foregroundStyle(Color.white)
                        .padding(.top, 12)
                        .onTapGesture { session.dismissStatus() }
                        .accessibilityIdentifier("statusBanner")
                }
            }
        }
        .navigationTitle("Problem")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { session.stop() }
    }

    private var controlBar: some View {
        HStack(spacing: 14) {
            Button {
                session.checkMyWork()
            } label: {
                Label("Check my work", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.isBusy)
            .accessibilityIdentifier("checkMyWorkButton")

            Label(session.isRecording ? "Listening..." : "Hold to ask", systemImage: session.isRecording ? "waveform" : "mic.fill")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(session.isRecording ? Color.red : Color.blue))
                .foregroundStyle(Color.white)
                .onLongPressGesture(minimumDuration: 0, maximumDistance: 80, perform: {}, onPressingChanged: { pressing in
                    session.holdToTalkChanged(pressed: pressing)
                })
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("holdToTalkButton")

            Button {
                session.clearMarks()
            } label: {
                Label("Clear marks", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .disabled(session.marks.isEmpty)
            .accessibilityIdentifier("clearMarksButton")

            Button(role: .destructive) {
                session.erasePage()
            } label: {
                Label("Erase page", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("erasePageButton")

            Spacer()

            if session.isBusy {
                ProgressView()
            }
            if LaunchOptions.showTestStatus {
                Text(session.testStatus)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("testStatus")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
