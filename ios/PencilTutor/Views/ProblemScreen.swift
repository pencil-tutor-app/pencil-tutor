import SwiftUI

struct ProblemScreen: View {
    @StateObject private var session: TutorSession
    @EnvironmentObject private var account: StudentAccount

    init(problem: Problem, env: AppEnvironment) {
        _session = StateObject(wrappedValue: TutorSession(problem: problem, env: env))
    }

    var body: some View {
        VStack(spacing: 0) {
            ProblemCardView(problem: session.problem)
            Divider()
            // Buttons sit above the page: the floating Pencil tool picker covers the bottom of the screen.
            controlBar
            if let block = account.block {
                BlockedBanner(message: block.message)
            }
            Divider()
            // The caption is a quiet backup for the voice: small, see-through, tucked in the top-right corner (students start
            // writing top-left; the floating Pencil tool picker covers the bottom). It goes away on tap or when the student writes.
            ZStack(alignment: .topTrailing) {
                InkCanvas(session: session)
                MarksOverlay(marks: session.marks, viewport: session.viewport)
                if let message = session.statusMessage {
                    Text(message)
                        .font(.system(size: 15))
                        .lineLimit(4)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: 340, alignment: .leading)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.primary)
                        .padding(.top, 8)
                        .padding(.trailing, 12)
                        .transition(.opacity)
                        .onTapGesture { session.dismissStatus() }
                        .accessibilityIdentifier("statusBanner")
                }
            }
            .animation(.easeOut(duration: 0.2), value: session.statusMessage)
        }
        .navigationTitle("Problem")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { session.begin() }
        .onDisappear { session.stop() }
    }

    /// The tutor's voice control. The base plan is tap to ask: tap once to talk, tap again to send. Live voice (only when the
    /// student's plan includes it) has a mute toggle instead. Nothing here once the hours are used up or the code is off.
    @ViewBuilder
    private var voiceControl: some View {
        if account.isBlocked {
            tapToAsk
        } else {
            voiceControlForPlan
        }
    }

    @ViewBuilder
    private var voiceControlForPlan: some View {
        switch session.voice {
        case .live(let micOn):
            Button {
                session.micTapped()
            } label: {
                Label(micOn ? "Mic on" : "Muted", systemImage: micOn ? "mic.fill" : "mic.slash.fill")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(micOn ? Color.green : Color.gray))
                    .foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("micToggleButton")
        case .connecting:
            Label("Connecting voice...", systemImage: "waveform")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.gray.opacity(0.25)))
                .accessibilityIdentifier("voiceConnecting")
        case .idleClosed:
            Button {
                session.micTapped()
            } label: {
                Label("Tap to talk", systemImage: "mic.fill")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.blue))
                    .foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("micReopenButton")
        case .fallback:
            // Only reachable when live voice is in the plan and then dropped.
            tapToAsk
            Button {
                session.micTapped()
            } label: {
                Label("Reconnect voice", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("reconnectVoiceButton")
        case .notStarted:
            tapToAsk
        }
    }

    /// Tap once to start talking, tap again to send. Stops by itself after 30 seconds.
    private var tapToAsk: some View {
        let listening = session.isRecording
        let off = account.isBlocked
        return Button {
            session.tapToTalkTapped()
        } label: {
            Label(listening ? "Listening... tap to send" : "Tap to ask", systemImage: listening ? "waveform" : "mic.fill")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(off ? Color.gray : (listening ? Color.red : Color.blue)))
                .foregroundStyle(Color.white)
        }
        .buttonStyle(.plain)
        .disabled(off)
        .accessibilityIdentifier("tapToTalkButton")
    }

    private var controlBar: some View {
        HStack(spacing: 14) {
            Button {
                session.checkMyWork()
            } label: {
                Label("Check my work", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.isBusy || account.isBlocked)
            .accessibilityIdentifier("checkMyWorkButton")

            voiceControl

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

            AllowanceChip()
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
