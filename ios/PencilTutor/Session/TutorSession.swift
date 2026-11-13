import Combine
import Foundation
import PencilKit
import UIKit

/// A red mark the tutor placed on the page. Lives on an overlay above the canvas, never inside the drawing.
struct Mark: Identifiable, Equatable {
    let id = UUID()
    let lineIndex: Int
    /// In canvas points.
    let box: CGRect
    let hint: String
    /// The ink under the mark when it was placed. If it changes and the tutor then sees no problem,
    /// the student fixed the line and the mark comes off (first device run, 2026-11-13: marks stayed forever).
    let inkSignature: String

    static func inkSignature(in box: CGRect, strokes: [InkStroke]) -> String {
        strokes
            .filter { $0.bounds.intersects(box) }
            .map { "\(Int($0.bounds.minX)),\(Int($0.bounds.minY)),\(Int($0.bounds.width)),\(Int($0.bounds.height))" }
            .sorted()
            .joined(separator: ";")
    }
}

/// One problem attempt: watches the ink, decides when to look, asks the tutor, and shows what comes back.
@MainActor
final class TutorSession: ObservableObject {
    enum LookTrigger: String {
        case idle
        case manual
    }

    let problem: Problem
    let sessionID = UUID().uuidString

    @Published private(set) var marks: [Mark] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    /// Read by UI tests only (see `LaunchOptions.showTestStatus`).
    @Published private(set) var testStatus = "strokes=0 lines=0 looks=0 last=none"

    private weak var canvas: PKCanvasView?
    private let env: AppEnvironment
    private let grouper = LineGrouper()
    private let recorder = AudioRecorder()
    private let now: () -> Date

    private var drawingRevision = 0
    private var lastLookRevision = 0
    private var lastInkAt: Date?
    private var lastInterruptionAt: Date?
    private var penDown = false
    private var penDownAt: Date?
    private var lookInFlight = false
    private var askInFlight = false
    private var talkHeld = false
    private var looksStarted = 0
    private var lastDecisionLabel = "none"
    private var lastLoggedSkip = ""
    private var history: [HistoryWire] = []
    private var checkTask: Task<Void, Never>?
    private var statusToken = 0

    init(problem: Problem, env: AppEnvironment, now: @escaping () -> Date = { Date() }) {
        self.problem = problem
        self.env = env
        self.now = now
        env.log.record("problem_opened", ["problem_id": problem.id])
    }

    // MARK: - Canvas events

    func attach(canvas: PKCanvasView) {
        self.canvas = canvas
    }

    /// Canvas diagnostics (touch types, swipe-back blocking, canvas size) go to the session log.
    /// Counts and labels only, never ink content.
    func noteCanvas(_ type: String, _ fields: [String: Any] = [:]) {
        env.log.record(type, fields.merging(["problem_id": problem.id]) { current, _ in current })
    }

    func penDidTouchDown() {
        penDown = true
        penDownAt = now()
        checkTask?.cancel()
    }

    func penDidLiftOff() {
        penDown = false
        scheduleCheck()
    }

    func drawingDidChange() {
        guard let canvas else { return }
        drawingRevision += 1
        lastInkAt = now()
        let strokes = Self.inkStrokes(from: canvas.drawing)
        let lines = grouper.group(strokes)
        refreshTestStatus(strokes: strokes.count, lines: lines.count)
        env.log.record("ink_changed", ["strokes": strokes.count, "lines": lines.count, "revision": drawingRevision])
        scheduleCheck()
    }

    // MARK: - Buttons

    func checkMyWork() {
        startLook(trigger: .manual)
    }

    func clearMarks() {
        guard !marks.isEmpty else { return }
        let count = marks.count
        marks = []
        env.log.record("marks_cleared", ["count": count])
    }

    func erasePage() {
        if let canvas, !canvas.drawing.strokes.isEmpty {
            // Undoable from the tool picker's undo button, so a fast wipe is never a lost page.
            let previous = canvas.drawing
            canvas.undoManager?.registerUndo(withTarget: canvas) { $0.drawing = previous }
            canvas.undoManager?.setActionName("Erase page")
        }
        canvas?.drawing = PKDrawing()
        marks = []
        env.log.record("page_erased", ["problem_id": problem.id])
        // Setting the drawing calls drawingDidChange through the delegate on some OS versions and not others,
        // so bump the revision here as well. A double bump is harmless.
        drawingRevision += 1
        refreshTestStatus(strokes: 0, lines: 0)
    }

    func holdToTalkChanged(pressed: Bool) {
        if pressed {
            guard !isRecording, !askInFlight, !talkHeld else { return }
            talkHeld = true
            Task { await beginRecording() }
        } else {
            talkHeld = false
            if isRecording { Task { await finishRecording() } }
        }
    }

    func stop() {
        checkTask?.cancel()
        env.speech.stop()
        if isRecording { _ = recorder.stop(); isRecording = false }
        env.log.record("problem_closed", ["problem_id": problem.id, "looks": looksStarted])
    }

    // MARK: - When to look

    private func scheduleCheck() {
        checkTask?.cancel()
        // A pen-down with no matching pen-up (a cancelled touch) must not block looking forever.
        let penStillDown = penDown && (penDownAt.map { now().timeIntervalSince($0) < 15 } ?? false)
        if penDown && !penStillDown {
            penDown = false
            env.log.record("pen_state_reset", ["why": "pen-down for over 15 s with no pen-up"])
        }
        let verdict = env.settings.policy.evaluate(
            now: now(),
            lastInkAt: lastInkAt,
            drawingRevision: drawingRevision,
            lastLookRevision: lastLookRevision,
            lastInterruptionAt: lastInterruptionAt,
            requestInFlight: lookInFlight,
            penDown: penStillDown
        )
        switch verdict {
        case .lookNow:
            startLook(trigger: .idle)
        case .waitUntil(let date, let reason):
            noteSkip("wait: \(reason)")
            let delay = max(0.05, date.timeIntervalSince(now()))
            checkTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.scheduleCheck()
            }
        case .skip(let reason):
            noteSkip("skip: \(reason)")
        }
    }

    /// Writes a skip reason to the log only when it changes, so the log shows why the tutor stayed quiet without flooding.
    private func noteSkip(_ label: String) {
        guard label != lastLoggedSkip else { return }
        lastLoggedSkip = label
        env.log.record("look_deferred", ["why": label, "revision": drawingRevision])
    }

    // MARK: - Looking

    private func startLook(trigger: LookTrigger) {
        guard !lookInFlight else {
            env.log.record("look_skipped", ["trigger": trigger.rawValue, "why": "a request is already in flight"])
            if trigger == .manual { setStatus("One moment, I'm still looking.") }
            return
        }
        guard let canvas else {
            env.log.record("look_skipped", ["trigger": trigger.rawValue, "why": "no canvas attached"])
            return
        }
        let size = canvas.bounds.size
        let drawing = canvas.drawing
        let strokes = Self.inkStrokes(from: drawing)
        let lines = grouper.group(strokes)
        guard !lines.isEmpty else {
            env.log.record("look_skipped", ["trigger": trigger.rawValue, "why": "no ink on the page"])
            if trigger == .manual { setStatus("Write some work first, then I'll check it.") }
            return
        }

        let revision = drawingRevision
        lastLookRevision = revision
        lookInFlight = true
        isBusy = true
        looksStarted += 1
        lastLoggedSkip = ""
        env.log.record("line_grouping", [
            "strokes": strokes.count, "lines": lines.count, "side_lines": lines.filter { $0.isSideCalculation }.count,
            "revision": revision
        ])
        refreshTestStatus(strokes: strokes.count, lines: lines.count)

        Task { await runLook(trigger: trigger, drawing: drawing, size: size, lines: lines, revision: revision) }
    }

    private func runLook(trigger: LookTrigger, drawing: PKDrawing, size: CGSize, lines: [InkLine], revision: Int) async {
        let started = now()
        do {
            let snapshot = try PageSnapshotter.make(drawing: drawing, canvasSize: size, lines: lines)
            let request = WatchRequest(
                sessionId: sessionID,
                problemId: problem.id,
                drawingRevision: revision,
                imagePngBase64: snapshot.png.base64EncodedString(),
                imageWidth: snapshot.pixelWidth,
                imageHeight: snapshot.pixelHeight,
                lines: lines.map { LineWire($0, scale: snapshot.scale) },
                history: Array(history.suffix(10)),
                clientTime: TimeText.iso(started)
            )
            env.log.record("look_started", [
                "trigger": trigger.rawValue, "revision": revision, "lines": lines.count,
                "image_bytes": snapshot.png.count, "image_px": "\(snapshot.pixelWidth)x\(snapshot.pixelHeight)",
                "history_items": request.history.count
            ])
            let response = try await env.client.watch(request)
            let latency = Int(now().timeIntervalSince(started) * 1000)
            handle(response, trigger: trigger, sentLines: lines, sentRevision: revision, latencyMs: latency)
        } catch {
            let (student, detail) = TutorError.describe(error)
            env.log.record("error", ["where": "watch", "trigger": trigger.rawValue, "detail": detail,
                                     "note": "no retry until the drawing changes or Check my work is pressed"])
            lastDecisionLabel = "error"
            refreshTestStatus()
            // Idle failures stay quiet on screen (the student did not ask); a button press always gets an answer.
            if trigger == .manual { setStatus(student) }
        }
        lookInFlight = false
        isBusy = false
        scheduleCheck()
    }

    private func handle(_ response: WatchResponse, trigger: LookTrigger, sentLines: [InkLine], sentRevision: Int, latencyMs: Int) {
        let echoedRevision = response.drawingRevision ?? sentRevision
        let reasonText = String((response.reason ?? "").prefix(200))
        var fields: [String: Any] = [
            "action": response.action, "trigger": trigger.rawValue, "latency_ms": latencyMs,
            "revision_sent": sentRevision, "revision_echoed": echoedRevision, "reason": reasonText
        ]
        if let line = response.line { fields["line"] = line }
        if let model = response.model { fields["model"] = model }
        if let serverMs = response.latencyMs { fields["server_latency_ms"] = serverMs }
        if let requestId = response.requestId { fields["request_id"] = requestId }

        switch response.action {
        case "interrupt":
            applyInterrupt(response, fields: fields, sentLines: sentLines, echoedRevision: echoedRevision)
        case "wait":
            env.log.record("decision", fields)
            lastDecisionLabel = "wait"
            appendHistory(action: "wait", line: nil, hint: nil)
            removeMarksOnFixedLines()
            if trigger == .manual {
                // The student asked, so answer out loud as well: silence after a button press reads as broken.
                let verdict = "Looks good so far. Keep going."
                setStatus(verdict)
                env.speech.speak(verdict, purpose: "check_ok")
            }
        default:
            fields["problem"] = "unknown action"
            env.log.record("error", ["where": "watch", "detail": "bad_response: unknown action '\(response.action)'"])
            lastDecisionLabel = "error"
            if trigger == .manual { setStatus(TutorError.badResponse(detail: "").studentMessage) }
        }
        refreshTestStatus()
    }

    /// Called when the tutor sees no problem: a mark whose ink changed since it was placed was fixed, so it comes off.
    /// A mark on an untouched line stays (the tutor waits because it already said its piece).
    private func removeMarksOnFixedLines() {
        guard !marks.isEmpty, let canvas else { return }
        let strokesNow = Self.inkStrokes(from: canvas.drawing)
        let fixed = marks.filter { Mark.inkSignature(in: $0.box, strokes: strokesNow) != $0.inkSignature }
        guard !fixed.isEmpty else {
            env.log.record("marks_kept", ["count": marks.count, "why": "marked lines unchanged"])
            return
        }
        let fixedIDs = Set(fixed.map(\.id))
        marks.removeAll { fixedIDs.contains($0.id) }
        env.log.record("marks_cleared", ["count": fixed.count, "lines": fixed.map(\.lineIndex),
                                         "why": "line rewritten and the tutor sees no problem", "remaining": marks.count])
    }

    private func applyInterrupt(_ response: WatchResponse, fields: [String: Any], sentLines: [InkLine], echoedRevision: Int) {
        var fields = fields
        guard let lineNumber = response.line, let sentLine = sentLines.first(where: { $0.index == lineNumber }) else {
            env.log.record("error", ["where": "watch", "detail": "bad_response: interrupt named line \(String(describing: response.line)) but only \(sentLines.count) lines were sent"])
            lastDecisionLabel = "error"
            return
        }
        let hintWritten = (response.hintWritten ?? response.hintSpoken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hintWritten.isEmpty else {
            env.log.record("error", ["where": "watch", "detail": "bad_response: interrupt without any hint text"])
            lastDecisionLabel = "error"
            return
        }

        // Find the same ink on the page now. If the student wrote more since, the line may have moved or changed.
        let currentLines = canvas.map { grouper.group(Self.inkStrokes(from: $0.drawing)) } ?? []
        let currentLine = currentLines.first(where: { $0.isSameInk(as: sentLine) })
        let outcome = StaleResponseGate.judge(
            responseRevision: echoedRevision,
            currentRevision: drawingRevision,
            lineStillUnchanged: currentLine != nil
        )
        if case .discard(let why) = outcome {
            fields["discarded_because"] = why
            env.log.record("discard", fields)
            lastDecisionLabel = "discarded"
            return
        }

        let box = currentLine?.box ?? sentLine.box
        let strokesNow = canvas.map { Self.inkStrokes(from: $0.drawing) } ?? []
        marks.append(Mark(lineIndex: lineNumber, box: box, hint: hintWritten,
                          inkSignature: Mark.inkSignature(in: box, strokes: strokesNow)))
        lastInterruptionAt = now()
        lastDecisionLabel = "interrupt"
        fields["hint_chars"] = hintWritten.count
        fields["hint_written"] = hintWritten
        fields["line_moved"] = currentLine.map { $0.index != lineNumber } ?? false
        env.log.record("decision", fields)
        appendHistory(action: "interrupt", line: lineNumber, hint: hintWritten)
        env.speech.speak(response.hintSpoken ?? hintWritten, purpose: "hint")
    }

    private func appendHistory(action: String, line: Int?, hint: String?) {
        history.append(HistoryWire(at: TimeText.iso(now()), action: action, line: line, hintWritten: hint))
        if history.count > 10 { history.removeFirst(history.count - 10) }
    }

    // MARK: - Hold to talk

    private func beginRecording() async {
        env.speech.stop()
        guard await recorder.ensurePermission() else {
            reportAskError(TutorError.microphoneDenied)
            talkHeld = false
            return
        }
        guard talkHeld else {
            env.log.record("ask_cancelled", ["why": "button released before recording could start"])
            return
        }
        do {
            try recorder.start()
            isRecording = true
            env.log.record("ask_recording_started", [:])
        } catch {
            reportAskError(error)
            talkHeld = false
            return
        }
        if !talkHeld { await finishRecording() }
    }

    private func finishRecording() async {
        guard isRecording, let recording = recorder.stop() else { return }
        isRecording = false
        defer { try? FileManager.default.removeItem(at: recording.url) }

        guard recording.duration >= AudioRecorder.minimumSeconds else {
            env.log.record("ask_cancelled", ["why": "recording too short", "seconds": recording.duration])
            reportAskError(TutorError.recordingTooShort)
            return
        }
        guard let canvas else { return }
        guard !askInFlight else { return }
        askInFlight = true
        isBusy = true
        let started = now()
        do {
            let audio = try Data(contentsOf: recording.url)
            let lines = grouper.group(Self.inkStrokes(from: canvas.drawing))
            let snapshot = try PageSnapshotter.make(drawing: canvas.drawing, canvasSize: canvas.bounds.size, lines: lines)
            let request = AskRequest(
                sessionId: sessionID,
                problemId: problem.id,
                drawingRevision: drawingRevision,
                audioBase64: audio.base64EncodedString(),
                imagePngBase64: snapshot.png.base64EncodedString()
            )
            env.log.record("ask_started", ["audio_bytes": audio.count, "audio_seconds": recording.duration,
                                           "image_bytes": snapshot.png.count, "lines": lines.count])
            let response = try await env.client.ask(request)
            let latency = Int(now().timeIntervalSince(started) * 1000)
            env.log.record("ask_answered", ["latency_ms": latency, "answer_chars": response.answerText.count,
                                            "model": response.model ?? "?", "request_id": response.requestId ?? "?"])
            setStatus(response.answerText, seconds: 20)
            env.speech.speak(response.answerText, purpose: "answer")
        } catch {
            reportAskError(error)
        }
        askInFlight = false
        isBusy = lookInFlight
    }

    private func reportAskError(_ error: Error) {
        let (student, detail) = TutorError.describe(error)
        env.log.record("error", ["where": "ask", "detail": detail])
        setStatus(student)
    }

    // MARK: - Small helpers

    private func setStatus(_ text: String?, seconds: Double = 8) {
        statusMessage = text
        statusToken += 1
        guard text != nil else { return }
        let token = statusToken
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.statusToken == token else { return }
            self.statusMessage = nil
        }
    }

    func dismissStatus() {
        setStatus(nil)
    }

    private func refreshTestStatus(strokes: Int? = nil, lines: Int? = nil) {
        guard LaunchOptions.showTestStatus else { return }
        let current = canvas.map { Self.inkStrokes(from: $0.drawing) } ?? []
        let strokeCount = strokes ?? current.count
        let lineCount = lines ?? grouper.group(current).count
        testStatus = "strokes=\(strokeCount) lines=\(lineCount) looks=\(looksStarted) last=\(lastDecisionLabel)"
    }

    nonisolated static func inkStrokes(from drawing: PKDrawing) -> [InkStroke] {
        drawing.strokes.enumerated().map { offset, stroke in
            InkStroke(id: offset, bounds: stroke.renderBounds, createdAt: stroke.path.creationDate)
        }
    }
}
