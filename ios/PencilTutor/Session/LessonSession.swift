import Foundation
import SwiftUI

/// One "Learn something new" lesson: the explanation, the conversation after it, and the practice problem that is made while the
/// student reads. It owns the lesson from the Start tap until the lesson screen is left, and the practice page shares it so a
/// question asked there lands in the same panel.
///
/// What it promises (docs/teach-mode-plan.md, Revision 2; docs/ipad-teach-mode.md):
///  - Nothing here times out. The panel changes only when the student taps something.
///  - The example's contents are never handed to the screen while its check is pending, and never if the check failed
///    (`visibleExample`). The check result arrives with the practice reply; the example slot says "Checking..." until then.
///  - A practice problem is offered only with the sealed reference the server made for it. If the server could not check one,
///    the student is told and may try again; there is no unchecked fallback and no automatic retry.
///  - It never starts the live voice. Speech is the base voice (`env.speech`), and tap to talk reuses `AudioRecorder`.
///  - Logs hold labels, counts and ids. The concept, the lesson and the questions appear only where Debug builds already keep words
///    (`TutorSession.logsWords`).
@MainActor
final class LessonSession: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        /// The server answered but will not teach this (not maths, another course). No retry: the student picks something else.
        case refused(String)
        /// The call failed; Try again sends the same concept again.
        case failed(String)
    }

    /// What the student may see of the example.
    enum ExampleState: Equatable {
        case pending
        case checked
        case withheld
        /// The check could not run (the practice call failed), so the example stays hidden and the panel says so.
        case notChecked
    }

    enum PracticeState: Equatable {
        case preparing
        case ready
        /// The server could not make a problem it was sure of.
        case notChecked
        case failed(String)
    }

    let courseSlug: String
    let concept: String
    let sessionID = UUID().uuidString

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var lesson: Lesson?
    @Published private(set) var exampleState: ExampleState = .pending
    @Published private(set) var practiceState: PracticeState = .preparing
    @Published private(set) var turns: [LessonTurn] = []
    @Published private(set) var isAnswering = false
    @Published private(set) var isRecording = false {
        didSet { env.speech.microphoneBusy = isRecording || talkRequested }
    }
    @Published private(set) var notice: String?
    /// Whether the side panel is open on the practice page. The lesson screen shows the panel all the time.
    @Published private(set) var panelOpen = false

    private(set) var practiceProblem: Problem?
    /// Set by the practice page: has the student a finished line of their own work (`AttemptRule`)?
    private(set) var practiceAttempted = false

    private let env: AppEnvironment
    private let now: () -> Date
    private let recorder = AudioRecorder()
    private var requestedAt: Date?
    private var started = false
    private var stopped = false
    private var lessonTask: Task<Void, Never>?
    private var practiceTask: Task<Void, Never>?
    private var talkRequested = false {
        didSet { env.speech.microphoneBusy = isRecording || talkRequested }
    }
    private var autoStopTask: Task<Void, Never>?
    private var followupInFlight = false

    init(courseSlug: String, concept: String, env: AppEnvironment, now: @escaping () -> Date = { Date() }) {
        self.courseSlug = courseSlug
        self.concept = concept
        self.env = env
        self.now = now
    }

    // MARK: - What the screens read

    /// The example, only when its check has passed. This is the one door the panel reads it through.
    var visibleExample: TeachExample? { exampleState == .checked ? lesson?.example : nil }

    /// "Your turn" is possible only with a problem the server checked.
    var canStartPractice: Bool { practiceState == .ready && practiceProblem != nil }

    /// The last 8 turns, for the server.
    var recent: [ConsultTurnWire] { LessonRecent.wire(turns) }

    // MARK: - Starting

    /// Asks for the lesson. Safe to call twice (the second call does nothing).
    func start() {
        guard !started else { return }
        started = true
        loadLesson(reason: "start")
    }

    /// Try again after a failed lesson.
    func retryLesson() {
        guard case .failed = phase else { return }
        loadLesson(reason: "retry")
    }

    private func loadLesson(reason: String) {
        if let block = env.account.block {
            phase = .failed(block.message)
            env.log.record("lesson_blocked", ["why": block.logLabel])
            return
        }
        phase = .loading
        let begun = now()
        requestedAt = begun
        var fields: [String: Any] = ["course": courseSlug, "concept_chars": concept.count, "reason": reason]
        if TutorSession.logsWords { fields["concept"] = concept }
        env.log.record("lesson_requested", fields)
        lessonTask?.cancel()
        lessonTask = Task { [weak self] in
            guard let self else { return }
            let request = TeachExplainRequest(sessionId: self.sessionID, course: self.courseSlug, concept: self.concept)
            do {
                let response = try await self.env.client.teachExplain(request)
                guard !self.stopped, !Task.isCancelled else { return }
                self.lessonArrived(response, begun: begun)
            } catch {
                guard !self.stopped, !Task.isCancelled else { return }
                let (student, detail) = TutorError.describe(error)
                self.phase = .failed(student)
                self.env.log.record("lesson_failed", ["detail": detail, "latency_ms": self.milliseconds(since: begun)])
            }
        }
    }

    private func lessonArrived(_ response: TeachExplainResponse, begun: Date) {
        let latency = milliseconds(since: begun)
        guard response.isMath else {
            phase = .refused(response.message ?? "I can teach maths topics only.")
            env.log.record("lesson_refused", ["reason": "not_math", "latency_ms": latency])
            return
        }
        // Past the course: the server teaches real maths anyway and says so in `message` (2026-11-28); only a reply without a
        // lesson is a refusal. The line is shown as the screen's notice above the lesson.
        let beyondCourse = !(response.fitsCourse ?? true)
        if beyondCourse && Lesson(response) == nil {
            phase = .refused(response.message ?? "That belongs to another course; pick it there.")
            env.log.record("lesson_refused", ["reason": "concept_outside_course", "latency_ms": latency])
            return
        }
        guard let lesson = Lesson(response) else {
            phase = .failed("I couldn't put that lesson together. Try again.")
            env.log.record("lesson_failed", ["detail": "reply_without_title_or_steps", "latency_ms": latency])
            return
        }
        self.lesson = lesson
        exampleState = .pending
        phase = .ready
        if beyondCourse { notice = response.message }
        env.log.record("lesson_shown", [
            "latency_ms": latency, "steps": lesson.steps.count, "example_lines": lesson.exampleLines,
            "model": response.model ?? "?", "request_id": response.requestId ?? "?",
            "server_latency_ms": response.latencyMs ?? -1, "beyond_course": beyondCourse
        ])
        if let spoken = lesson.spoken, !spoken.isEmpty { env.speech.speak(spoken, purpose: "lesson") }
        requestPractice(reason: "prefetch")
    }

    // MARK: - The practice problem

    /// "I couldn't make a practice problem I'm sure of. Try again?" Each tap is one generate plus two checks on the server.
    func tryPracticeAgain() {
        guard practiceState == .notChecked || isPracticeFailure else { return }
        requestPractice(reason: "try_again")
    }

    /// The practice page found its reference too old (`practice_expired`): make a new problem.
    func newPractice(reason: String) {
        practiceProblem = nil
        practiceAttempted = false
        requestPractice(reason: reason)
    }

    private var isPracticeFailure: Bool {
        if case .failed = practiceState { return true }
        return false
    }

    private func requestPractice(reason: String) {
        guard let lesson, !stopped else { return }
        if let block = env.account.block {
            practiceState = .failed(block.message)
            env.log.record("practice_blocked", ["why": block.logLabel])
            return
        }
        practiceState = .preparing
        let begun = now()
        practiceTask?.cancel()
        practiceTask = Task { [weak self] in
            guard let self else { return }
            let request = TeachPracticeRequest(
                sessionId: self.sessionID, course: self.courseSlug, concept: self.concept,
                lessonText: lesson.text(includeExample: false), example: lesson.example
            )
            do {
                let response = try await self.env.client.teachPractice(request)
                guard !self.stopped, !Task.isCancelled else { return }
                self.practiceArrived(response, reason: reason, begun: begun)
            } catch {
                guard !self.stopped, !Task.isCancelled else { return }
                let (student, detail) = TutorError.describe(error)
                self.practiceState = .failed(student)
                if self.exampleState == .pending { self.exampleState = .notChecked }
                self.env.log.record("practice_failed", ["detail": detail, "reason": reason, "latency_ms": self.milliseconds(since: begun)])
            }
        }
    }

    private func practiceArrived(_ response: TeachPracticeResponse, reason: String, begun: Date) {
        let latency = milliseconds(since: begun)
        // Only a check that says yes shows the example. A reply that does not say (an older server) keeps it out of sight.
        let exampleChecked = response.exampleChecked == true
        // Only a pending example can become visible. A rejection is final: a later practice call that happens to accept it does
        // not bring it back, and a later rejection takes a shown example away again.
        switch (exampleState, exampleChecked) {
        case (.pending, true), (.notChecked, true):
            exampleState = .checked
        case (_, false):
            if exampleState != .withheld {
                env.log.record("example_withheld", ["reason": response.exampleChecked == nil ? "no_answer_from_server" : "check_rejected"])
            }
            exampleState = .withheld
        default:
            break
        }
        guard let problem = response.problem, let ref = response.problemRef, !ref.isEmpty,
              !problem.promptPlain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            practiceProblem = nil
            practiceState = .notChecked
            env.log.record("practice_not_checked", [
                "reason": response.reason ?? "no_problem", "example_checked": exampleChecked, "trigger": reason, "latency_ms": latency
            ])
            return
        }
        practiceProblem = Problem.practice(courseSlug: courseSlug, promptPlain: problem.promptPlain, ref: ref)
        practiceState = .ready
        env.log.record("practice_ready", [
            "reference": "checked", "example_checked": exampleChecked, "trigger": reason, "latency_ms": latency,
            "model": response.model ?? "?", "request_id": response.requestId ?? "?", "prompt_chars": problem.promptPlain.count
        ])
    }

    /// The practice page tells the lesson whether the student has a finished line (so follow-ups carry `attempted`).
    func notePracticeAttempted(_ attempted: Bool) {
        practiceAttempted = attempted
    }

    func practiceStarted() {
        env.log.record("practice_started", ["course": courseSlug])
    }

    // MARK: - Conversation

    /// A typed follow-up.
    func ask(typed: String) {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sendFollowup(question: text, audio: nil)
    }

    /// The practice page answered a question: keep both sides in the panel and in `recent`.
    func noteExchange(student: String?, tutor: String) {
        if let student, !student.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            turns.append(LessonTurn(role: .student, text: student))
        }
        turns.append(LessonTurn(role: .tutor, text: tutor))
    }

    private func sendFollowup(question: String?, audio: Data?) {
        guard let lesson, phase == .ready else { return }
        if let block = env.account.block {
            notice = block.message
            env.log.record("lesson_followup_ignored", ["why": block.logLabel])
            return
        }
        guard !followupInFlight else {
            notice = "One moment, I'm still thinking about your last question."
            env.log.record("lesson_followup_ignored", ["why": "the last question is still being answered"])
            return
        }
        followupInFlight = true
        isAnswering = true
        notice = nil
        env.speech.stop()
        let begun = now()
        let sentRecent = recent
        // A typed question is on the panel at once; a spoken one appears when the server has heard it.
        if let question { turns.append(LessonTurn(role: .student, text: question)) }
        let reference = practiceState == .ready ? practiceProblem?.problemRef : nil
        let request = TeachFollowupRequest(
            sessionId: sessionID, course: courseSlug, concept: concept,
            lessonText: lesson.text(includeExample: exampleState == .checked), recent: sentRecent,
            question: question, audioBase64: audio?.base64EncodedString(),
            problemText: reference == nil ? nil : practiceProblem?.promptPlain,
            problemRef: reference, attempted: reference == nil ? nil : practiceAttempted
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.env.client.teachFollowup(request)
                let latency = self.milliseconds(since: begun)
                guard !self.stopped else { return }
                if question == nil, let heard = response.transcript, !heard.isEmpty { self.turns.append(LessonTurn(role: .student, text: heard)) }
                self.turns.append(LessonTurn(role: .tutor, text: response.answerText))
                var fields: [String: Any] = [
                    "input": audio == nil ? "typed" : "voice", "chars": (question ?? response.transcript ?? "").count,
                    "recent_turns": sentRecent.count, "latency_ms": latency, "answer_chars": response.answerText.count,
                    "model": response.model ?? "?", "request_id": response.requestId ?? "?", "attempted": request.attempted ?? false
                ]
                if TutorSession.logsWords {
                    fields["question"] = question ?? response.transcript ?? ""
                    fields["answer"] = response.answerText
                }
                self.env.log.record("lesson_followup", fields)
                self.env.speech.speak(response.answerText, purpose: "lesson_answer")
            } catch {
                guard !self.stopped else { return }
                let (student, detail) = TutorError.describe(error)
                self.notice = student
                self.env.log.record("lesson_followup_failed", ["input": audio == nil ? "typed" : "voice", "detail": detail])
            }
            self.followupInFlight = false
            self.isAnswering = false
        }
    }

    // MARK: - Tap to talk

    /// Tap once to talk, tap again to send. Stops by itself after 30 seconds.
    func tapToTalk() {
        if let block = env.account.block {
            notice = block.message
            env.log.record("lesson_followup_ignored", ["why": block.logLabel])
            return
        }
        if isRecording {
            Task { await finishRecording(reason: "second_tap") }
        } else if talkRequested {
            talkRequested = false
        } else if followupInFlight {
            notice = "One moment, I'm still thinking about your last question."
        } else {
            talkRequested = true
            Task { await beginRecording() }
        }
    }

    private func beginRecording() async {
        env.speech.stop()
        guard await recorder.ensurePermission() else {
            notice = TutorError.microphoneDenied.studentMessage
            talkRequested = false
            return
        }
        guard talkRequested, !stopped else {
            talkRequested = false
            return
        }
        do {
            try recorder.start()
            isRecording = true
            env.log.record("lesson_recording_started", ["max_seconds": AudioRecorder.maximumSeconds])
            autoStopTask?.cancel()
            autoStopTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(AudioRecorder.maximumSeconds * 1_000_000_000))
                guard !Task.isCancelled, let self, self.isRecording else { return }
                await self.finishRecording(reason: "auto_stop")
            }
        } catch {
            notice = TutorError.describe(error).student
            env.log.record("error", ["where": "lesson_recording", "detail": TutorError.describe(error).detail])
            talkRequested = false
        }
    }

    private func finishRecording(reason: String) async {
        autoStopTask?.cancel()
        autoStopTask = nil
        guard isRecording, let recording = recorder.stop() else { return }
        isRecording = false
        talkRequested = false
        defer { try? FileManager.default.removeItem(at: recording.url) }
        env.log.record("lesson_recording_stopped", ["reason": reason, "seconds": recording.duration])
        guard recording.duration >= AudioRecorder.minimumSeconds else {
            notice = TutorError.recordingTooShort.studentMessage
            return
        }
        guard let audio = try? Data(contentsOf: recording.url) else {
            notice = TutorError.recordingFailed(detail: "unreadable").studentMessage
            return
        }
        sendFollowup(question: nil, audio: audio)
    }

    // MARK: - The side panel on the practice page

    func openPanel() {
        guard !panelOpen else { return }
        panelOpen = true
        env.log.record("lesson_panel_reopened", ["turns": turns.count])
    }

    func closePanel() {
        guard panelOpen else { return }
        panelOpen = false
        env.log.record("lesson_panel_closed", ["turns": turns.count])
    }

    // MARK: - Leaving

    /// The lesson screen was left for good (not for the practice page).
    func stop() {
        guard !stopped else { return }
        stopped = true
        lessonTask?.cancel()
        practiceTask?.cancel()
        autoStopTask?.cancel()
        if isRecording { _ = recorder.stop(); isRecording = false }
        talkRequested = false
        env.speech.stop()
        env.log.record("lesson_closed", ["turns": turns.count, "practice": String(describing: practiceStateLabel)])
    }

    private var practiceStateLabel: String {
        switch practiceState {
        case .preparing: return "preparing"
        case .ready: return "ready"
        case .notChecked: return "not_checked"
        case .failed: return "failed"
        }
    }

    private func milliseconds(since date: Date) -> Int { Int(now().timeIntervalSince(date) * 1000) }
}
