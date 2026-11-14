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
