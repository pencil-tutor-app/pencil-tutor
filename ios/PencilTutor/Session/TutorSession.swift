import Combine
import Foundation
import PencilKit
import UIKit

/// A red mark the tutor placed on the page. Lives on an overlay above the canvas, never inside the drawing.
struct Mark: Identifiable, Equatable {
    let id: UUID
    let lineIndex: Int
    /// In canvas points.
    let box: CGRect
    let hint: String
    /// The ink under the mark when it was placed. If it changes and the tutor then sees no problem,
    /// the student fixed the line and the mark comes off (first device run, 2026-11-13: marks stayed forever).
    let inkSignature: String
    /// The strokes of the flagged line (who they are, not where they sit), so "Not a mistake" can be remembered against that ink.
    let inkIdentity: InkIdentity
    /// Which server answer put this mark here, for the dispute log line. Ids only.
    let requestID: String?
    let model: String?

    init(id: UUID = UUID(), lineIndex: Int, box: CGRect, hint: String, inkSignature: String,
         inkIdentity: InkIdentity = .none, requestID: String? = nil, model: String? = nil) {
        self.id = id
        self.lineIndex = lineIndex
        self.box = box
        self.hint = hint
        self.inkSignature = inkSignature
        self.inkIdentity = inkIdentity
        self.requestID = requestID
        self.model = model
    }

    static func inkSignature(in box: CGRect, strokes: [InkStroke]) -> String {
        strokes
            .filter { $0.bounds.intersects(box) }
            .map { "\(Int($0.bounds.minX)),\(Int($0.bounds.minY)),\(Int($0.bounds.width)),\(Int($0.bounds.height))" }
            .sorted()
            .joined(separator: ";")
    }

    /// The same mark after the whole drawing was moved by `shift` (a page re-anchor). The ink signature is moved with it, so a
    /// mark on untouched ink still looks untouched. Shifts are whole points, so the arithmetic on the signature is exact.
    func moved(by shift: CGSize) -> Mark {
        let dx = Int(shift.width), dy = Int(shift.height)
        let movedSignature = inkSignature.split(separator: ";").map { entry -> String in
            let parts = entry.split(separator: ",").compactMap { Int($0) }
            guard parts.count == 4 else { return String(entry) }
            return "\(parts[0] + dx),\(parts[1] + dy),\(parts[2]),\(parts[3])"
        }.sorted().joined(separator: ";")
        // Same id (the voice's bookkeeping and the on-screen button follow the mark), same ink identity (strokes do not change
        // when the whole page moves).
        return Mark(id: id, lineIndex: lineIndex, box: box.offsetBy(dx: shift.width, dy: shift.height), hint: hint,
                    inkSignature: movedSignature, inkIdentity: inkIdentity, requestID: requestID, model: model)
    }
}

/// One problem attempt: watches the ink, decides when to look, asks the tutor, and shows what comes back.
///
/// Voice: the base plan is tap to ask (tap the microphone, ask, tap again; `/api/ask` answers and `/api/speak` says it in the
/// tutor's voice, with the device voice as the last fallback). When the student's plan includes live voice
/// (`/api/me` says `live: true`, default false) a problem also opens a GPT-Live session (`LiveVoice`); if that cannot connect
/// or drops, the session falls back to tap to ask and says why in the log. `voice` says which of those the screen is in.
///
/// Hours: the account tells this session when the month's hours are used up or the code is turned off. Then it stops
/// looking, asking and talking, and leaves drawing alone. While a problem is open it also sends a heartbeat every 30 seconds
/// that reports when the student last really did something (ink, live talk), if that is new, so the server counts only real
/// working time (`ActivityMeter`).
@MainActor
final class TutorSession: ObservableObject {
    enum LookTrigger: String {
        case idle
        case manual
    }

    /// Which voice path this screen is on. The mic control on screen follows it.
    enum VoiceMode: Equatable {
        /// No live voice (the default: base plan, scripted UI tests, unconfigured server): tap to ask only.
        case notStarted
        case connecting
        case live(micOn: Bool)
        /// Live failed or dropped. Tap to ask works; `reason` is also in the session log.
        case fallback(reason: String)
        /// Live was closed for being idle or for the app going to the background. The old path speaks hints; the mic button reopens Live.
        case idleClosed
    }

    let problem: Problem
    let sessionID = UUID().uuidString

    @Published private(set) var voice: VoiceMode = .notStarted
    @Published private(set) var marks: [Mark] = []
    /// How far the page is scrolled and how tall it is. The marks overlay follows it; not `@Published` here on purpose
    /// (a scroll changes it every frame and must not redraw the whole screen).
    let viewport = CanvasViewport()
    @Published private(set) var statusMessage: String?
    @Published private(set) var isRecording = false {
        didSet { syncSpeechWithMicrophone() }
    }
    @Published private(set) var isBusy = false
    /// The server said the practice problem's sealed reference is too old (`practice_expired`). The screen offers a new problem.
    @Published private(set) var practiceExpired = false
    /// Read by UI tests only (see `LaunchOptions.showTestStatus`).
    @Published private(set) var testStatus = "strokes=0 lines=0 looks=0 last=none"

    private weak var canvas: PKCanvasView?
    /// The page in unzoomed page points as last set (`PageGeometry.contentSize`); the scroll view's own contentSize is this times the zoom.
    private var pageSize = CGSize.zero
    /// The first screen has been scrolled into place (once per problem; Erase page does it again).
    private var placedHome = false
    /// How far down the floating problem card reaches (screen points from the top of the page view), plus a margin; 0 until the
    /// card has been measured. Home is placed this far down so writing starts under the card, and a mark never stays under it.
    private var cardBottomInWindow: CGFloat?
    /// The clearance the page was last placed with, to tell whether the card has moved since.
    private var placedClearance: CGFloat = 0
    /// The student has scrolled or zoomed since home was placed, so home is no longer moved when the card changes size.
    private var studentMovedPage = false
    /// True while the drawing is being moved by a re-anchor, so the change callback does not count it as writing.
    private var reanchoring = false
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
    /// The tool of the latest gesture ("ink", "lasso", "eraser", "other"), so the log can say what produced a change.
    private var lastTool = "ink"
    private var lastStrokeCount = 0
    private var lookInFlight = false
    private var askInFlight = false
    /// The student tapped the microphone and recording is starting or running (a permission prompt may still be open).
    private var talkRequested = false {
        didSet { syncSpeechWithMicrophone() }
    }
    private var autoStopTask: Task<Void, Never>?
    private var activity = ActivityMeter()
    private var heartbeatTask: Task<Void, Never>?
    private var lastHeartbeatLabel = ""
    private var inForeground = true
    private var blockObserver: AnyCancellable?
    private var looksStarted = 0
    private var lastDecisionLabel = "none"
    private var lastLoggedSkip = ""
    private var history: [HistoryWire] = []
    /// Practice problems only: what the student has really started (`AttemptRule`), and the last value told to the lesson and to
    /// the live voice. Nil until first judged.
    private var attempts = AttemptTracker()
    private var attemptedNow: Bool?
    private let lesson: LessonSession?
    /// Ink the student said the tutor was wrong about ("Not a mistake"). Checked before any later circle is drawn.
    private var disputes = DisputeBook()
    /// The line number of every dispute made on this screen, in order. A page report that was being read when one was made is
    /// marked with the ones made since it started (see `answer`).
    private var disputedLines: [Int] = []
    /// The mark whose hint was last handed to a voice, and which route took it. Only that mark's dismissal may stop the voice:
    /// dismissing an old circle must not cut off the hint of a newer one.
    private var hintInVoice: (markID: UUID, route: String)?
    private var checkTask: Task<Void, Never>?
    private var statusToken = 0

    private var live: LiveVoice?
    private var begun = false
    /// Set by `stop()`. Answers that arrive after the screen closed are dropped and logged, never spoken.
    private var stopped = false
    private var delegationTasks: [String: Task<Void, Never>] = [:]
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    /// The previous screen's live session may still be shutting down when the next problem opens. One live audio owner at a
    /// time: a new connection waits for this to finish.
    private static var previousTeardown: Task<Void, Never>?

    init(problem: Problem, env: AppEnvironment, lesson: LessonSession? = nil, now: @escaping () -> Date = { Date() }) {
        self.problem = problem
        self.env = env
        self.lesson = lesson
        self.now = now
        env.log.record("problem_opened", ["problem_id": problem.id, "kind": problem.kindLabel])
        // The first value arrives at once; later ones when the hours run out, come back, or the code is turned off.
        blockObserver = env.account.$block.removeDuplicates().sink { [weak self] block in
            self?.accountBlockChanged(block)
        }
    }

    // MARK: - Canvas events

    func attach(canvas: PKCanvasView) {
        self.canvas = canvas
        syncPageSize(reason: "canvas_attached")
    }

    // MARK: - The endless page

    /// Keeps the page where `PageGeometry` says: the first screen and the ink, plus one screen in every direction, and the scroll
    /// position inside it. Runs after every drawing change (so the page grows as the student writes toward any edge and shrinks
    /// when ink is deleted or erased), when the view changes size, and when a page is erased. Moves the drawing and the marks
    /// right/down first if ink has come close to the left or top edge (`reanchorPage`). Logs only when the size actually changes.
    func syncPageSize(reason: String) {
        guard let canvas else { return }
        let visible = canvas.bounds.size
        guard visible.width > 1, visible.height > 1 else {
            // Not laid out yet; the resize callback calls this again once it has a size.
            env.log.record("page_resize_deferred", ["reason": reason, "why": "canvas not laid out yet", "problem_id": problem.id])
            return
        }
        var ink = Self.inkBounds(of: canvas.drawing)
        if let shift = PageGeometry.reanchorShift(viewport: visible, ink: ink) {
            reanchorPage(by: shift, reason: reason)
            ink = Self.inkBounds(of: canvas.drawing)
        }
        let zoom = canvas.zoomScale
        let target = PageGeometry.contentSize(viewport: visible, ink: ink)
        if target != pageSize {
            let before = pageSize
            pageSize = target
            // The scroll view's contentSize is in zoomed (screen) points.
            canvas.contentSize = CGSize(width: target.width * zoom, height: target.height * zoom)
            var fields: [String: Any] = [
                "reason": reason, "from": "\(Int(before.width))x\(Int(before.height))", "to": "\(Int(target.width))x\(Int(target.height))",
                "zoom": String(format: "%.2f", zoom), "screen": "\(Int(visible.width))x\(Int(visible.height))",
                "ink_box": ink.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.maxX)),\(Int($0.maxY))" } ?? "none",
                "problem_id": problem.id
            ]
            let growsRight = target.width > before.width, growsDown = target.height > before.height
            if before != .zero, growsRight || growsDown {
                fields["direction"] = [growsRight ? "right" : nil, growsDown ? "down" : nil].compactMap { $0 }.joined(separator: "_")
                env.log.record("page_grew", fields)
            } else {
                env.log.record("page_resized", fields)
            }
        }
        if !placedHome {
            // First sizing of this page (or a fresh page after Erase page): show the first screen, not the blank reserve.
            placedHome = true
            studentMovedPage = false
            placeHome(zoom: zoom, reason: reason)
        }
        // A shrink (erase, delete, lasso cut) can leave the screen past the new end of the page: pull it back.
        // (A rubber-band overscroll past an edge is left alone; only a screen past the end is pulled back.)
        let clamped = PageGeometry.clampedOffset(canvas.contentOffset, contentSize: canvas.contentSize, viewport: visible)
        if canvas.contentOffset.x > clamped.x + 0.5 || canvas.contentOffset.y > clamped.y + 0.5 {
            let from = canvas.contentOffset
            canvas.setContentOffset(clamped, animated: false)
            env.log.record("page_scroll_clamped", ["from": "\(Int(from.x)),\(Int(from.y))", "to": "\(Int(clamped.x)),\(Int(clamped.y))",
                                                   "reason": reason, "problem_id": problem.id])
        }
        viewport.update(offset: canvas.contentOffset, contentSize: canvas.contentSize, zoomScale: zoom)
    }

    /// How far down the problem card (or its folded pill) reaches from the top of the page view, in screen points, plus a margin.
    /// 0 while the card has not been measured or the page is not on screen yet.
    private var topClearance: CGFloat {
        guard let canvas, canvas.window != nil, let bottom = cardBottomInWindow else { return 0 }
        // The canvas is a scroll view: its bounds start at the scroll position, so the top of what is on screen is the bounds
        // origin, not the point (0, 0) of its content.
        return max(0, bottom - canvas.convert(canvas.bounds.origin, to: nil).y) + PageGeometry.cardMargin
    }

    /// Scrolls to the first screen, with the page's origin `topClearance` below the top so the first line of work is not under
    /// the problem card. Logs where it went and why.
    private func placeHome(zoom: CGFloat, reason: String) {
        guard let canvas else { return }
        let clearance = topClearance
        placedClearance = clearance
        canvas.setContentOffset(PageGeometry.homeOffset(zoom: zoom, topClearance: clearance), animated: false)
        env.log.record("page_home_placed", ["offset": "\(Int(canvas.contentOffset.x)),\(Int(canvas.contentOffset.y))",
                                            "zoom": String(format: "%.2f", zoom), "card_clearance": Int(clearance),
                                            "reason": reason, "problem_id": problem.id])
    }

    /// The screen view measured the bottom edge of the problem card (window coordinates). The card is measured after the page
    /// first lays out, and again when it folds, unfolds or rewraps. While the page is still blank and the student has not scrolled
    /// or zoomed, home follows the card; once there is ink or the student has moved the page, nothing is scrolled behind their
    /// back (a mark that ends up under the card is scrolled clear of it instead, `scrollToShow`).
    func cardMeasured(bottomInWindow: CGFloat) {
        guard bottomInWindow > 0 else { return }       // the preference's starting value, not a measurement
        cardBottomInWindow = bottomInWindow
        guard let canvas, placedHome, abs(topClearance - placedClearance) >= 1 else { return }
        let follows = canvas.drawing.strokes.isEmpty && !studentMovedPage && canvas.zoomScale == 1
        env.log.record("card_measured", ["clearance": Int(topClearance), "was": Int(placedClearance), "moves_home": follows,
                                         "problem_id": problem.id])
        guard follows else { return }
        placeHome(zoom: 1, reason: "card_measured")
        viewport.update(offset: canvas.contentOffset, contentSize: canvas.contentSize, zoomScale: canvas.zoomScale)
    }

    /// Ink is within a margin of the left or top edge of the page, and a scroll view cannot grow leftwards or upwards. So the
    /// whole drawing and the tutor's marks move right/down by `shift`, and the scroll position moves the same distance so the
    /// student sees nothing move. This is the one time drawing coordinates change; it is rare (about 1800 pt left of or above
    /// the first screen) and it is logged. The undo history is dropped: its steps describe the old coordinates. Look requests
    /// already in flight name boxes in the old coordinates; their answers fail the same-ink check and are discarded.
    private func reanchorPage(by shift: CGSize, reason: String) {
        guard let canvas else { return }
        let zoom = canvas.zoomScale
        reanchoring = true
        canvas.drawing = canvas.drawing.transformed(using: CGAffineTransform(translationX: shift.width, y: shift.height))
        canvas.undoManager?.removeAllActions()
        reanchoring = false
        marks = marks.map { $0.moved(by: shift) }
        let offset = canvas.contentOffset
        // The page is about to be resized by the caller; set the offset after, from the same numbers, so UIKit cannot clamp it.
        let target = CGPoint(x: offset.x + shift.width * zoom, y: offset.y + shift.height * zoom)
        let grown = PageGeometry.contentSize(viewport: canvas.bounds.size, ink: Self.inkBounds(of: canvas.drawing))
        pageSize = grown
        canvas.contentSize = CGSize(width: grown.width * zoom, height: grown.height * zoom)
        canvas.setContentOffset(target, animated: false)
        env.log.record("page_reanchored", [
            "reason": reason, "shift": "\(Int(shift.width)),\(Int(shift.height))", "marks_moved": marks.count,
            "new_size": "\(Int(grown.width))x\(Int(grown.height))", "zoom": String(format: "%.2f", zoom),
            "note": "undo history cleared", "problem_id": problem.id
        ])
    }

    /// "x1200-2224,y1500-2100": the part of the page in a picture, for the log.
    nonisolated static func regionLabel(_ region: CGRect) -> String {
        "x\(Int(region.minX))-\(Int(region.maxX)),y\(Int(region.minY))-\(Int(region.maxY))"
    }

    /// The box around all the ink, in page points; nil for an empty page or if PencilKit reports a bound that is not a number.
    nonisolated static func inkBounds(of drawing: PKDrawing) -> CGRect? {
        let boxes = drawing.strokes.map { $0.renderBounds }.filter { PageGeometry.isUsable($0) }
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
    }

    func viewportDidScroll(to offset: CGPoint) {
        // Also called while pinching, so the zoom and the page size are read here too.
        viewport.update(offset: offset, contentSize: canvas?.contentSize, zoomScale: canvas?.zoomScale)
    }

    /// One log line per finished scroll (not per frame), so the log shows where the student has been looking.
    func viewportDidSettle(at offset: CGPoint) {
        studentMovedPage = true
        viewport.update(offset: offset, contentSize: canvas?.contentSize, zoomScale: canvas?.zoomScale)
        let zoom = canvas?.zoomScale ?? 1
        env.log.record("page_scrolled", [
            "offset": "\(Int(offset.x)),\(Int(offset.y))", "page": "\(Int(pageSize.width))x\(Int(pageSize.height))",
            "zoom": String(format: "%.2f", zoom), "problem_id": problem.id
        ])
    }

    /// One log line per finished pinch. The page size is set again for the new zoom (the scroll view's size is zoomed), so
    /// `contentSize` stays what `PageGeometry` says whatever the scroll view does with it while zooming.
    func viewportDidZoomSettle(scale: CGFloat) {
        guard let canvas else { return }
        studentMovedPage = true
        let reported = canvas.contentSize
        let expected = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
        env.log.record("zoom_settled", [
            "scale": String(format: "%.2f", scale), "content_reported": "\(Int(reported.width))x\(Int(reported.height))",
            "content_expected": "\(Int(expected.width))x\(Int(expected.height))",
            "offset": "\(Int(canvas.contentOffset.x)),\(Int(canvas.contentOffset.y))", "problem_id": problem.id
        ])
        if abs(reported.width - expected.width) > 2 || abs(reported.height - expected.height) > 2 {
            // The scroll view did not scale the content with the zoom the way a plain UIScrollView does: put it right.
            canvas.contentSize = expected
            env.log.record("zoom_content_corrected", ["scale": String(format: "%.2f", scale), "problem_id": problem.id])
        }
        viewport.update(offset: canvas.contentOffset, contentSize: canvas.contentSize, zoomScale: scale)
    }

    /// When the tutor circles a line that is off screen (or too close to the edge for its callout), the page scrolls to it,
    /// in both directions. The zoom stays as the student set it.
    private func scrollToShow(_ box: CGRect, lineIndex: Int) {
        guard let canvas else { return }
        let zoom = canvas.zoomScale
        guard let target = PageGeometry.offsetToReveal(box: box, offset: canvas.contentOffset, zoom: zoom,
                                                       viewport: canvas.bounds.size, contentSize: canvas.contentSize,
                                                       topClearance: topClearance) else {
            env.log.record("mark_in_view", ["line": lineIndex, "offset": "\(Int(canvas.contentOffset.x)),\(Int(canvas.contentOffset.y))",
                                            "zoom": String(format: "%.2f", zoom), "problem_id": problem.id])
            return
        }
        env.log.record("scrolled_to_mark", [
            "line": lineIndex, "from": "\(Int(canvas.contentOffset.x)),\(Int(canvas.contentOffset.y))",
            "to": "\(Int(target.x)),\(Int(target.y))", "zoom": String(format: "%.2f", zoom), "card_clearance": Int(topClearance),
            "mark_box": "\(Int(box.minX)),\(Int(box.minY)),\(Int(box.maxX)),\(Int(box.maxY))", "problem_id": problem.id
        ])
        canvas.setContentOffset(target, animated: true)
    }

    /// Canvas diagnostics (touch types, swipe-back blocking, canvas size) go to the session log.
    /// Counts and labels only, never ink content.
    func noteCanvas(_ type: String, _ fields: [String: Any] = [:]) {
        env.log.record(type, fields.merging(["problem_id": problem.id]) { current, _ in current })
    }

    /// A gesture with a canvas tool began. `tool` is "ink", "lasso", "eraser" or "other". A lasso loop or a selection drag is
    /// not writing: it only holds the look back while it lasts (like a pen that is down), and whether it changed the page is
    /// decided later by `drawingDidChange`, which fires only if the ink really changed (a delete, cut, paste or move).
    func penDidTouchDown(tool: String = "ink") {
        penDown = true
        penDownAt = now()
        lastTool = tool
        checkTask?.cancel()
        if tool != "ink" {
            env.log.record("tool_began", ["tool": tool, "revision": drawingRevision, "problem_id": problem.id])
        }
    }

    func penDidLiftOff() {
        penDown = false
        scheduleCheck()
    }

    func drawingDidChange() {
        // Moving the drawing for a page re-anchor is not writing: no new revision, no look.
        guard let canvas, !reanchoring else { return }
        drawingRevision += 1
        lastInkAt = now()
        activity.note(.ink, at: now())
        let strokes = Self.inkStrokes(from: canvas.drawing)
        let lines = grouper.group(strokes)
        refreshTestStatus(strokes: strokes.count, lines: lines.count)
        // strokes_delta below zero means ink went away (lasso delete or cut, eraser); zero with the lasso is a move; above
        // zero is writing or a paste. last_tool is the tool of the latest gesture (an undo from the rail keeps the old label).
        env.log.record("ink_changed", [
            "strokes": strokes.count, "lines": lines.count, "revision": drawingRevision,
            "strokes_delta": strokes.count - lastStrokeCount, "last_tool": lastTool
        ])
        lastStrokeCount = strokes.count
        syncPageSize(reason: "ink_changed")
        removeMarksWhoseInkIsGone(strokes: strokes)
        endDisputesOnEditedInk(strokes: strokes)
        live?.noteActivity()
        // The caption is a backup for the voice; once the student writes again it is in the way, so it goes.
        if statusMessage != nil {
            setStatus(nil)
            env.log.record("caption_hidden", ["why": "student_wrote"])
        }
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
            // Undoable from the rail's undo button or a two-finger tap, so a fast wipe is never a lost page.
            let previous = canvas.drawing
            canvas.undoManager?.registerUndo(withTarget: canvas) { [weak self] restored in
                restored.drawing = previous
                // Undo runs on the main thread. The page must grow back to hold the restored ink even on OS versions where
                // setting the drawing does not call the delegate.
                MainActor.assumeIsolated { self?.syncPageSize(reason: "erase_undone") }
            }
            canvas.undoManager?.setActionName("Erase page")
        }
        canvas?.drawing = PKDrawing()
        marks = []
        if problem.isPractice {
            attempts.reset()
            noteAttempted(false, source: "page_erased")
        }
        let endedDisputes = disputes.removeAll()
        hintInVoice = nil
        if endedDisputes > 0 { env.log.record("disputes_ended", ["count": endedDisputes, "why": "page_erased", "problem_id": problem.id]) }
        env.log.record("page_erased", [
            "problem_id": problem.id, "was_scrolled_to": "\(Int(canvas?.contentOffset.x ?? 0)),\(Int(canvas?.contentOffset.y ?? 0))",
            "was_zoom": String(format: "%.2f", canvas?.zoomScale ?? 1)
        ])
        // Back to the first screen at normal size. (`syncPageSize` shrinks the content and scrolls to the first screen; the zoom
        // is reset first so the page size it sets is in unzoomed points.)
        canvas?.setZoomScale(1, animated: false)
        placedHome = false
        lastStrokeCount = 0
        syncPageSize(reason: "page_erased")
        // Setting the drawing calls drawingDidChange through the delegate on some OS versions and not others,
        // so bump the revision here as well. A double bump is harmless.
        drawingRevision += 1
        refreshTestStatus(strokes: 0, lines: 0)
    }

    /// Ink under a mark that is gone (deleted or cut with the lasso, erased, or moved elsewhere) takes its mark with it: a red
    /// circle around blank paper helps nobody. Ink that is merely edited keeps its mark; the next look decides about that.
    private func removeMarksWhoseInkIsGone(strokes: [InkStroke]) {
        guard !marks.isEmpty else { return }
        let gone = marks.filter { $0.inkSignature != "" && Mark.inkSignature(in: $0.box, strokes: strokes).isEmpty }
        guard !gone.isEmpty else { return }
        let goneIDs = Set(gone.map(\.id))
        marks.removeAll { goneIDs.contains($0.id) }
        env.log.record("marks_cleared", ["count": gone.count, "lines": gone.map(\.lineIndex),
                                         "why": "ink under the mark was deleted or moved away", "remaining": marks.count])
    }

    /// The base plan's microphone button: tap once to start recording a question, tap again to stop and send it. Recording
    /// also stops and sends by itself at 30 seconds, and is dropped if the student leaves the problem.
    func tapToTalkTapped() {
        if let block = env.account.block {
            env.log.record("ask_ignored", ["why": block.logLabel])
            setStatus(block.message)
            return
        }
        // While the live voice owns the microphone, the tap-to-ask button is not on screen; this is a guard, not a path.
        switch voice {
        case .live, .connecting, .idleClosed:
            env.log.record("ask_ignored", ["why": "live voice owns the microphone"])
            return
        case .notStarted, .fallback:
            break
        }
        if isRecording {
            env.log.record("ask_stop_tapped", [:])
            Task { await finishRecording(reason: "second_tap") }
        } else if talkRequested {
            // The permission prompt or the start is still going: a second tap takes the request back.
            talkRequested = false
            env.log.record("ask_cancelled", ["why": "tapped again before recording started"])
        } else if askInFlight {
            env.log.record("ask_ignored", ["why": "the last question is still being answered"])
            setStatus("One moment, I'm still thinking about your last question.")
        } else {
            talkRequested = true
            Task { await beginRecording() }
        }
    }

    func stop() {
        stopped = true
        checkTask?.cancel()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        autoStopTask?.cancel()
        autoStopTask = nil
        blockObserver = nil
        delegationTasks.values.forEach { $0.cancel() }
        delegationTasks = [:]
        env.speech.stop()
        if isRecording {
            _ = recorder.stop()
            isRecording = false
            env.log.record("ask_cancelled", ["why": "left the problem while recording"])
        }
        talkRequested = false
        if begun { env.account.problemClosed() }
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
            self.backgroundObserver = nil
        }
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
        }
        if let closing = live {
            live = nil
            let previous = Self.previousTeardown
            Self.previousTeardown = Task {
                await previous?.value
                await closing.close(reason: "problem_closed")
            }
        }
        env.log.record("problem_closed", ["problem_id": problem.id, "looks": looksStarted])
    }

    // MARK: - Live voice

    /// Runs when the screen appears. Idempotent. Counts the time (heartbeat), checks the code and plan with the server
    /// (`/api/me`), and opens live voice only if the plan includes it.
    func begin() {
        guard !begun else { return }
        begun = true
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.appDidEnterBackground() }
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.appWillEnterForeground() }
        }
        env.account.problemOpened()
        startHeartbeatLoop()
        Task { await openLiveVoiceIfThePlanAllows() }
    }

    /// Asks the server about the plan (this also wakes the database), then decides about live voice. The default plan has
    /// no live voice, so the usual outcome is a log line saying why and nothing else.
    private func openLiveVoiceIfThePlanAllows() async {
        await env.account.refresh(reason: "problem_opened")
        guard !stopped else { return }
        guard !LaunchOptions.silent else {
            env.log.record("live_skipped", ["reason": "silent_test_launch", "problem_id": problem.id])
            return
        }
        guard env.makeLiveTransport != nil else {
            env.log.record("live_skipped", ["reason": env.liveOffReason ?? "unknown", "problem_id": problem.id])
            return
        }
        if let block = env.account.block {
            env.log.record("live_skipped", ["reason": block.logLabel, "problem_id": problem.id])
            return
        }
        guard env.account.liveAllowed else {
            env.log.record("live_skipped", [
                "reason": env.account.plan == nil ? "plan_unknown_so_base_plan" : "plan_live_false", "problem_id": problem.id
            ])
            return
        }
        startLive(greet: true, trigger: "problem_opened")
    }

    // MARK: - Hours: heartbeat and blocked mode

    private func startHeartbeatLoop() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(ActivityMeter.heartbeatInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.heartbeatTick()
            }
        }
    }

    private func heartbeatTick() async {
        let at = now()
        // Live voice talk is activity too, but it never reaches the server as a request, so the heartbeat carries it.
        if let spoke = live?.lastStudentSpeechAt { activity.note(.speech, at: spoke) }
        let decision = activity.decide(now: at, problemOpen: !stopped, inForeground: inForeground, blocked: env.account.isBlocked)
        guard case .send(let kind, let secondsAgo) = decision else {
            // Logged when the reason changes, so a quiet student shows one line and not one a minute.
            if decision.label != lastHeartbeatLabel {
                lastHeartbeatLabel = decision.label
                env.log.record("heartbeat_skipped", ["reason": decision.label, "problem_id": problem.id])
            }
            return
        }
        lastHeartbeatLabel = ""
        activity.noteHeartbeatSent(at: at)
        env.log.record("heartbeat_sending", ["after": kind.rawValue, "seconds_since_activity": secondsAgo, "problem_id": problem.id])
        do {
            let reply = try await env.client.heartbeat(HeartbeatRequest(sessionId: sessionID, problemId: problem.id, secondsSinceActivity: secondsAgo))
            env.log.record("heartbeat_ok", [
                "remaining_minutes": reply.allowance.remainingMinutes, "state": reply.allowance.state.rawValue,
                "elapsed_ms": Int(now().timeIntervalSince(at) * 1000)
            ])
        } catch {
            let (_, detail) = TutorError.describe(error)
            activity.noteHeartbeatFailed()
            env.log.record("heartbeat_failed", ["detail": detail, "next": "report the same activity on the next beat"])
        }
    }

    /// The hours ran out or the code was turned off (or it came back). The tutor stops looking, asking and talking;
    /// drawing is untouched.
    private func accountBlockChanged(_ block: StudentAccount.Block?) {
        guard let block else { return }
        env.log.record("session_blocked", ["reason": block.logLabel, "problem_id": problem.id])
        checkTask?.cancel()
        autoStopTask?.cancel()
        autoStopTask = nil
        if isRecording {
            _ = recorder.stop()
            isRecording = false
            env.log.record("ask_cancelled", ["why": block.logLabel])
        }
        talkRequested = false
        if live != nil {
            closeLive(reason: block.logLabel)
            voice = .notStarted
        }
    }

    private func closeLive(reason: String) {
        guard let closing = live else { return }
        live = nil
        let previous = Self.previousTeardown
        Self.previousTeardown = Task {
            await previous?.value
            await closing.close(reason: reason)
        }
    }

    private func appWillEnterForeground() {
        inForeground = true
        env.log.record("app_foreground", ["problem_id": problem.id])
    }

    /// The live mic control. While live it mutes and unmutes; after an idle close or a fallback it asks for the live voice
    /// again. Only on screen when the student's plan includes live voice.
    func micTapped() {
        switch voice {
        case .live(let micOn):
            live?.setMic(on: !micOn)
            voice = .live(micOn: !micOn)
        case .idleClosed:
            startLive(greet: false, trigger: "mic_tapped_after_close")
        case .fallback:
            startLive(greet: false, trigger: "reconnect_tapped")
        case .connecting, .notStarted:
            break
        }
    }

    private func startLive(greet: Bool, trigger: String) {
        guard !stopped, let makeTransport = env.makeLiveTransport else { return }
        voice = .connecting
        env.speech.stop()
        if isRecording { _ = recorder.stop(); isRecording = false }
        autoStopTask?.cancel()
        autoStopTask = nil
        talkRequested = false
        env.log.record("live_starting", ["trigger": trigger, "problem_id": problem.id])

        let voiceSession = LiveVoice(
            problemID: problem.id, problemText: problem.problemTextForServer, problemRef: problem.problemRef,
            appSessionID: sessionID, transport: makeTransport(),
            createSession: { [env] request in try await env.client.createLiveSession(request) },
            ensureMicrophone: env.ensureMicrophone,
            log: env.log
        )
        voiceSession.onDelegation = { [weak self, weak voiceSession] delegation in
            guard let self, let voiceSession else { return }
            self.beginDelegation(delegation, from: voiceSession)
        }
        voiceSession.onEnded = { [weak self, weak voiceSession] reason in
            guard let self, let voiceSession, self.live === voiceSession else { return }
            self.liveEnded(reason: reason)
        }
        live = voiceSession

        let previous = Self.previousTeardown
        Task { [weak self] in
            await previous?.value
            let failure = await voiceSession.connect(greet: greet)
            guard let self else { return }
            if self.stopped || self.live !== voiceSession {
                if failure == nil { await voiceSession.close(reason: "superseded_while_connecting") }
                return
            }
            if let failure {
                self.switchToFallback(reason: failure.reason)
            } else {
                self.voice = .live(micOn: true)
                self.pushPracticeContext(to: voiceSession, label: "practice_opened")
            }
        }
    }

    private func switchToFallback(reason: String) {
        env.log.record("live_fallback", ["reason": reason, "to": "tap_to_ask_ask_and_speak", "problem_id": problem.id])
        live = nil
        voice = .fallback(reason: reason)
        setStatus(reason == "microphone_denied" ? TutorError.microphoneDenied.studentMessage
                  : "Voice chat isn't working right now. You can still tap the microphone to ask me a question.")
    }

    /// The live session ended without the app asking (idle, dropped, ended by OpenAI).
    private func liveEnded(reason: String) {
        live = nil
        if reason == "idle" {
            env.log.record("live_paused", ["reason": reason, "next": "hints speak the old way; mic button reopens live"])
            voice = .idleClosed
            setStatus("Voice paused. Tap the microphone when you want to talk again.")
        } else {
            switchToFallback(reason: reason)
        }
    }

    private func appDidEnterBackground() {
        inForeground = false
        env.log.record("app_background", ["problem_id": problem.id])
        guard let closing = live, !stopped else { return }
        env.log.record("live_paused", ["reason": "app_backgrounded", "next": "mic button reopens live"])
        live = nil
        voice = .idleClosed
        let previous = Self.previousTeardown
        Self.previousTeardown = Task {
            await previous?.value
            await closing.close(reason: "app_backgrounded")
        }
    }

    /// One place every spoken line goes through, so there is one audio owner: the live voice while it is connected,
    /// the earlier speech path otherwise (fallback, idle close, no live voice in this build).
    @discardableResult
    private func tell(_ text: String, purpose: String) -> String {
        if let live, live.say(text, purpose: purpose) {
            env.log.record("speech_route", ["purpose": purpose, "via": "live"])
            return "live"
        }
        env.log.record("speech_route", ["purpose": purpose, "via": "speech_output", "voice": Self.voiceLabel(voice)])
        env.speech.speak(text, purpose: purpose)
        return "speech_output"
    }

    private static func voiceLabel(_ mode: VoiceMode) -> String {
        switch mode {
        case .notStarted: return "not_started"
        case .connecting: return "connecting"
        case .live: return "live"
        case .fallback: return "fallback"
        case .idleClosed: return "idle_closed"
        }
    }

    private func pushVerdict(lineCount: Int, flaggedLine: Int?, hintWritten: String?) {
        live?.pushContext(LiveContext.verdict(lineCount: lineCount, flaggedLine: flaggedLine, hintWritten: hintWritten), label: "look_verdict")
    }

    // MARK: - Delegation: GPT-Live cannot see, so it asks us to read the page

    private func beginDelegation(_ delegation: LiveVoice.Delegation, from session: LiveVoice) {
        guard live === session, !stopped else {
            env.log.record("live_delegation_dropped", ["delegation_id": delegation.id, "reason": "session_replaced_or_screen_closed"])
            return
        }
        delegationTasks[delegation.id] = Task { [weak self] in
            await self?.answer(delegation, from: session)
            self?.delegationTasks[delegation.id] = nil
        }
    }

    /// Captures the page now, asks `/api/consult`, and returns the report to the live voice. A result that arrives after the
    /// session closed is dropped. If the drawing changed while the page was being read, the page is read once more; if it
    /// changed again, the report goes out marked as possibly out of date.
    private func answer(_ delegation: LiveVoice.Delegation, from session: LiveVoice) async {
        var attempt = 0
        // Disputes made after this point happened while the page was being read; the report must not undo them.
        let disputesAtStart = disputedLines.count
        while true {
            attempt += 1
            guard live === session, !stopped, session.isStillWaiting(on: delegation.id) else {
                env.log.record("live_delegation_dropped", ["delegation_id": delegation.id, "reason": "session_ended_or_screen_closed", "attempt": attempt])
                return
            }
            guard let canvas else {
                session.failDelegation(id: delegation.id, reason: "the page is not on screen")
                return
            }
            let revisionSent = drawingRevision
            let lines = grouper.group(Self.inkStrokes(from: canvas.drawing))
            guard !lines.isEmpty else {
                env.log.record("live_consult_skipped", ["delegation_id": delegation.id, "why": "no ink on the page"])
                session.answerDelegation(id: delegation.id, text: LiveContext.emptyPage)
                return
            }
            do {
                let snapshot = try PageSnapshotter.make(drawing: canvas.drawing, canvasSize: canvas.bounds.size, lines: lines)
                env.log.savePageImage(snapshot.png, kind: "consult", lookID: "d\(delegation.id)-a\(attempt)-r\(revisionSent)")  // Debug builds only
                let request = ConsultRequest(
                    sessionId: sessionID, problemId: problem.id, drawingRevision: revisionSent,
                    imagePngBase64: snapshot.png.base64EncodedString(), question: delegation.question, recent: delegation.recent,
                    problemText: problem.problemTextForServer, problemRef: problem.problemRef,
                    attempted: practiceFields(for: canvas.drawing).attempted
                )
                env.log.record("live_consult_started", [
                    "delegation_id": delegation.id, "attempt": attempt, "revision": revisionSent, "lines": lines.count,
                    "image_bytes": snapshot.png.count, "image_px": "\(snapshot.pixelWidth)x\(snapshot.pixelHeight)",
                    "region": Self.regionLabel(snapshot.region),
                    "question_chars": delegation.question.count, "recent_turns": delegation.recent.count
                ].merging(request.attempted.map { ["attempted": $0] } ?? [:]) { current, _ in current })
                let started = now()
                let response = try await env.client.consult(request)
                let latency = Int(now().timeIntervalSince(started) * 1000)
                guard live === session, !stopped, !Task.isCancelled, session.isStillWaiting(on: delegation.id) else {
                    env.log.record("live_delegation_dropped", [
                        "delegation_id": delegation.id, "reason": "late_result_after_close", "latency_ms": latency
                    ])
                    return
                }
                let pageChanged = drawingRevision != revisionSent
                var fields: [String: Any] = [
                    "delegation_id": delegation.id, "attempt": attempt, "latency_ms": latency,
                    "answer_chars": response.answerText.count, "page_changed": pageChanged,
                    "model": response.model ?? "?", "request_id": response.requestId ?? "?"
                ]
                if let serverMs = response.latencyMs { fields["server_latency_ms"] = serverMs }
                if pageChanged && attempt == 1 {
                    fields["next"] = "read the page again"
                    env.log.record("live_consult_stale", fields)
                    continue
                }
                if Self.logsWords { fields["page_report"] = response.answerText }
                env.log.record("live_consult_answered", fields)
                let disputedMeanwhile = Array(disputedLines.dropFirst(disputesAtStart))
                if !disputedMeanwhile.isEmpty {
                    env.log.record("live_consult_dispute_note", [
                        "delegation_id": delegation.id, "lines": disputedMeanwhile,
                        "why": "the student dismissed a circle while this page report was being read"
                    ])
                }
                session.answerDelegation(
                    id: delegation.id,
                    text: response.answerText
                        + (disputedMeanwhile.isEmpty ? "" : LiveContext.disputedNote(lines: disputedMeanwhile))
                        + (pageChanged ? LiveContext.outOfDateNote : ""),
                    stale: pageChanged
                )
                return
            } catch {
                noteIfPracticeExpired(error)
                let (_, detail) = TutorError.describe(error)
                env.log.record("error", ["where": "live_consult", "delegation_id": delegation.id, "detail": detail])
                if live === session, !stopped {
                    session.failDelegation(id: delegation.id, reason: Self.plainReason(error))
                }
                return
            }
        }
    }

    private static func plainReason(_ error: Error) -> String {
        switch error as? TutorError {
        case .some(.timedOut): return "it took too long"
        case .some(.offline): return "no internet connection"
        case .some(.snapshotFailed): return "the picture of the page failed"
        default: return "a problem on the server"
        }
    }

    // MARK: - When to look

    private func scheduleCheck() {
        checkTask?.cancel()
        if let block = env.account.block {
            noteSkip("skip: \(block.logLabel)")
            return
        }
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
        if let block = env.account.block {
            env.log.record("look_skipped", ["trigger": trigger.rawValue, "why": block.logLabel])
            if trigger == .manual { setStatus(block.message) }
            return
        }
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
        activity.note(.look, at: now())
        lookInFlight = true
        isBusy = true
        looksStarted += 1
        lastLoggedSkip = ""
        env.log.record("line_grouping", [
            "strokes": strokes.count, "lines": lines.count, "side_lines": lines.filter { $0.isSideCalculation }.count,
            "revision": revision
        ])
        refreshTestStatus(strokes: strokes.count, lines: lines.count)
        if problem.isPractice { noteAttempted(attempts.look(strokes), source: "look") }

        let lookID = "w\(looksStarted)-r\(revision)"
        Task { await runLook(trigger: trigger, drawing: drawing, size: size, lines: lines, revision: revision, lookID: lookID) }
    }

    private func runLook(trigger: LookTrigger, drawing: PKDrawing, size: CGSize, lines: [InkLine], revision: Int, lookID: String) async {
        let started = now()
        do {
            let snapshot = try PageSnapshotter.make(drawing: drawing, canvasSize: size, lines: lines)
            env.log.savePageImage(snapshot.png, kind: "watch", lookID: lookID)  // Debug builds only
            // Only the lines inside the picture are sent, with boxes measured from the picture's top edge. On a page that
            // fits the picture this is every line, unchanged; on a long page the window may start below the first lines.
            let shownLines = lines.filter { snapshot.shows($0) }
            let request = WatchRequest(
                sessionId: sessionID,
                problemId: problem.id,
                drawingRevision: revision,
                imagePngBase64: snapshot.png.base64EncodedString(),
                imageWidth: snapshot.pixelWidth,
                imageHeight: snapshot.pixelHeight,
                lines: shownLines.map { LineWire($0, scale: snapshot.scale, regionOrigin: snapshot.region.origin) },
                history: Array(history.suffix(10)),
                clientTime: TimeText.iso(started),
                problemText: problem.problemTextForServer,
                problemRef: problem.problemRef
            )
            env.log.record("look_started", [
                "trigger": trigger.rawValue, "revision": revision, "lines": lines.count, "lines_sent": shownLines.count,
                "image_bytes": snapshot.png.count, "image_px": "\(snapshot.pixelWidth)x\(snapshot.pixelHeight)",
                "region": Self.regionLabel(snapshot.region), "scale": String(format: "%.3f", snapshot.scale),
                "history_items": request.history.count
            ])
            let response = try await env.client.watch(request)
            let latency = Int(now().timeIntervalSince(started) * 1000)
            if stopped {
                // The screen closed while the look was in flight: no mark, no speech.
                env.log.record("look_dropped", ["reason": "screen_closed", "latency_ms": latency, "action": response.action])
            } else {
                handle(response, trigger: trigger, sentLines: shownLines, sentRevision: revision, latencyMs: latency)
            }
        } catch {
            noteIfPracticeExpired(error)
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
        if !stopped { scheduleCheck() }
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
            applyInterrupt(response, trigger: trigger, fields: fields, sentLines: sentLines, echoedRevision: echoedRevision)
        case "wait":
            env.log.record("decision", fields)
            lastDecisionLabel = "wait"
            appendHistory(action: "wait", line: nil, hint: nil)
            removeMarksOnFixedLines()
            pushVerdict(lineCount: sentLines.count, flaggedLine: nil, hintWritten: nil)
            if trigger == .manual {
                // The student asked, so answer out loud as well: silence after a button press reads as broken.
                setStatus(LiveContext.checkLooksGood)
                tell(LiveContext.checkLooksGood, purpose: "check_ok")
            }
        default:
            fields["problem"] = "unknown action"
            env.log.record("error", ["where": "watch", "detail": "bad_response: unknown action '\(response.action)'"])
            lastDecisionLabel = "error"
            if trigger == .manual { setStatus(TutorError.badResponse(detail: "").studentMessage) }
        }
        refreshTestStatus()
    }

    /// Test builds (Debug) also log the words: what the student asked and what the tutor said. Edward asked for the
    /// full conversation in the log to tune the tutor (2026-11-13). Release builds keep counts only.
    #if DEBUG
    static let logsWords = true
    #else
    static let logsWords = false
    #endif

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

    private func applyInterrupt(_ response: WatchResponse, trigger: LookTrigger, fields: [String: Any], sentLines: [InkLine], echoedRevision: Int) {
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
        // The student already said the tutor was wrong about this very ink. However the lines are numbered now, and however many
        // looks have passed, it is not circled again; the voice is not told either.
        let flaggedInk = InkIdentity(line: currentLine ?? sentLine, in: strokesNow)
        if let dispute = disputes.covering(flaggedInk) {
            suppressDisputedInterrupt(dispute, lineNumber: lineNumber, trigger: trigger, fields: fields)
            return
        }
        let mark = Mark(lineIndex: lineNumber, box: box, hint: hintWritten,
                        inkSignature: Mark.inkSignature(in: box, strokes: strokesNow),
                        inkIdentity: flaggedInk, requestID: response.requestId, model: response.model)
        marks.append(mark)
        scrollToShow(box, lineIndex: lineNumber)
        lastInterruptionAt = now()
        lastDecisionLabel = "interrupt"
        fields["hint_chars"] = hintWritten.count
        fields["hint_written"] = hintWritten
        if Self.logsWords { fields["hint_spoken"] = response.hintSpoken ?? "" }
        fields["line_moved"] = currentLine.map { $0.index != lineNumber } ?? false
        env.log.record("decision", fields)
        appendHistory(action: "interrupt", line: lineNumber, hint: hintWritten)
        // The circle is on the page and the live voice is told about it first, then given the hint to say.
        pushVerdict(lineCount: sentLines.count, flaggedLine: lineNumber, hintWritten: hintWritten)
        let route = tell(response.hintSpoken ?? hintWritten, purpose: "hint")
        hintInVoice = (mark.id, route)
    }

    // MARK: - "Not a mistake"

    /// The tutor circled ink the student has already dismissed. Nothing is drawn, said or counted as an interruption (so the quiet
    /// time after a real circle does not start). A look the student asked for still gets an answer: "looks good", because the
    /// only thing the tutor had left to say was the dismissed line. The history tells the server which line it was this time.
    private func suppressDisputedInterrupt(_ dispute: Dispute, lineNumber: Int, trigger: LookTrigger, fields: [String: Any]) {
        var fields = fields
        fields["reason"] = nil   // the model's own words stay out of this line: it is about a decision the student overruled
        fields["disputed_line"] = dispute.lineIndex
        if let id = dispute.requestID { fields["disputed_request_id"] = id }
        fields["disputes"] = disputes.count
        fields["problem_id"] = problem.id
        env.log.record("interrupt_suppressed_disputed", fields)
        lastDecisionLabel = "suppressed"
        appendHistory(action: "disputed", line: lineNumber, hint: nil)
        if trigger == .manual {
            setStatus(LiveContext.checkLooksGood)
            tell(LiveContext.checkLooksGood, purpose: "check_ok")
        }
    }

    /// The student tapped "Not a mistake" on a circle. The circle comes off at once and the ink it was on is remembered by its
    /// strokes, so the same ink is never circled again, whatever the line is numbered and wherever the page has moved to. The voice
    /// is told too: a hint still waiting is dropped, one being spoken on the base voice is stopped, and the live voice gets a
    /// quiet "do not repeat that" line.
    func markNotAMistake(_ markID: UUID) {
        guard let mark = marks.first(where: { $0.id == markID }) else {
            env.log.record("mark_dispute_ignored", ["why": "mark_already_gone", "problem_id": problem.id])
            return
        }
        let page = canvas.map { Self.inkStrokes(from: $0.drawing) } ?? []
        let ink = disputedInk(of: mark, page: page)
        marks.removeAll { $0.id == markID }
        if ink.isEmpty {
            env.log.record("mark_dispute_unkeyed", ["line": mark.lineIndex, "why": "no ink under the mark to remember", "problem_id": problem.id])
        } else {
            disputes.add(Dispute(lineIndex: mark.lineIndex, requestID: mark.requestID, ink: ink))
        }
        disputedLines.append(mark.lineIndex)
        env.log.record("mark_disputed", [
            "line": mark.lineIndex, "request_id": mark.requestID ?? "?", "model": mark.model ?? "?",
            "strokes": ink.strokes.count, "disputes": disputes.count, "marks_left": marks.count, "problem_id": problem.id
        ])
        appendHistory(action: "disputed", line: mark.lineIndex, hint: nil)
        takeBackHint(of: mark)
        refreshTestStatus()
    }

    /// The ink to remember for a dismissed mark: the line under the mark now (the student may have added a stroke since the circle
    /// was drawn, and means the line as they see it); the ink the tutor judged if no line is under it any more.
    private func disputedInk(of mark: Mark, page: [InkStroke]) -> InkIdentity {
        let lines = grouper.group(page)
        func overlap(_ line: InkLine) -> CGFloat {
            let shared = line.box.intersection(mark.box)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        if let best = lines.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 {
            return InkIdentity(line: best, in: page)
        }
        return mark.inkIdentity
    }

    /// A disputed line's ink is gone or redrawn: the dispute ends, and the tutor may circle what is there now.
    private func endDisputesOnEditedInk(strokes: [InkStroke]) {
        let ended = disputes.dropEdited(page: strokes)
        guard !ended.isEmpty else { return }
        env.log.record("disputes_ended", [
            "count": ended.count, "lines": ended.map(\.lineIndex), "remaining": disputes.count,
            "why": "disputed ink was erased or redrawn", "problem_id": problem.id
        ])
    }

    /// Ties the dismissal to the hint and the work still pending for it, then says what was done (labels only):
    ///  - held behind a page report in the live voice: dropped;
    ///  - already sent to the live voice as commentary: cannot be recalled, so the live voice is told to stop and not repeat it;
    ///  - being spoken on the base voice (or being fetched for it): stopped;
    ///  - a page report still being read, whose late answer would go straight to the live voice: marked (see `answer`).
    /// A dismissal of an older circle leaves the voice alone when a newer hint has taken its place.
    private func takeBackHint(of mark: Mark) {
        var paths: [String] = []
        let ownsVoice = hintInVoice?.markID == mark.id
        if ownsVoice {
            paths += live?.retractHint(reason: "disputed") ?? []
            if env.speech.stopIfSpeaking(purpose: "hint", reason: "hint_disputed") { paths.append("base_voice_stopped") }
            hintInVoice = nil
        }
        let told = live?.pushContext(LiveContext.notAMistake(line: mark.lineIndex), label: "mark_disputed") ?? false
        let consultsInFlight = delegationTasks.count
        if consultsInFlight > 0 { paths.append("consult_in_flight_will_carry_a_note") }
        env.log.record("hint_taken_back", [
            "line": mark.lineIndex, "voice_still_had_this_hint": ownsVoice,
            "paths": paths.isEmpty ? "nothing_pending" : paths.joined(separator: ","),
            "live_told": told, "consults_in_flight": consultsInFlight, "problem_id": problem.id
        ])
    }

    private func appendHistory(action: String, line: Int?, hint: String?) {
        history.append(HistoryWire(at: TimeText.iso(now()), action: action, line: line, hintWritten: hint))
        if history.count > 10 { history.removeFirst(history.count - 10) }
    }

    // MARK: - Tap to talk

    /// The tutor never talks over the student: while the microphone is recording or about to, speech is blocked and
    /// anything already playing is cut off. A server voice that arrives late is dropped the same way.
    private func syncSpeechWithMicrophone() {
        env.speech.microphoneBusy = isRecording || talkRequested
    }

    private func beginRecording() async {
        env.speech.stop()
        guard await recorder.ensurePermission() else {
            reportAskError(TutorError.microphoneDenied)
            talkRequested = false
            return
        }
        guard talkRequested, !stopped, env.account.block == nil else {
            env.log.record("ask_cancelled", ["why": "tapped again, left the problem or hours ran out before recording could start"])
            talkRequested = false
            return
        }
        do {
            try recorder.start()
            isRecording = true
            activity.note(.question, at: now())
            env.log.record("ask_recording_started", ["max_seconds": AudioRecorder.maximumSeconds])
            startAutoStop()
        } catch {
            reportAskError(error)
            talkRequested = false
        }
    }

    /// Stops and sends the question by itself at 30 seconds, so a forgotten second tap never records for ever.
    private func startAutoStop() {
        autoStopTask?.cancel()
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AudioRecorder.maximumSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isRecording else { return }
            self.env.log.record("ask_auto_stopped", ["after_seconds": AudioRecorder.maximumSeconds])
            await self.finishRecording(reason: "auto_stop_after_\(Int(AudioRecorder.maximumSeconds))s")
        }
    }

    private func finishRecording(reason: String) async {
        autoStopTask?.cancel()
        autoStopTask = nil
        guard isRecording, let recording = recorder.stop() else { return }
        isRecording = false
        talkRequested = false
        env.log.record("ask_recording_stopped", ["reason": reason, "seconds": recording.duration])
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
            let practice = practiceFields(for: canvas.drawing)
            let lines = grouper.group(Self.inkStrokes(from: canvas.drawing))
            let snapshot = try PageSnapshotter.make(drawing: canvas.drawing, canvasSize: canvas.bounds.size, lines: lines)
            let request = AskRequest(
                sessionId: sessionID,
                problemId: problem.id,
                drawingRevision: drawingRevision,
                audioBase64: audio.base64EncodedString(),
                imagePngBase64: snapshot.png.base64EncodedString(),
                problemText: problem.problemTextForServer,
                problemRef: practice.problemRef,
                attempted: practice.attempted,
                recent: practice.recent
            )
            var askFields: [String: Any] = ["audio_bytes": audio.count, "audio_seconds": recording.duration,
                                            "image_bytes": snapshot.png.count, "lines": lines.count,
                                            "image_px": "\(snapshot.pixelWidth)x\(snapshot.pixelHeight)",
                                            "region": Self.regionLabel(snapshot.region)]
            if let attempted = request.attempted { askFields["attempted"] = attempted }
            if let recent = request.recent { askFields["recent_turns"] = recent.count }
            env.log.record("ask_started", askFields)
            let response = try await env.client.ask(request)
            let latency = Int(now().timeIntervalSince(started) * 1000)
            var answered: [String: Any] = ["latency_ms": latency, "answer_chars": response.answerText.count,
                                           "model": response.model ?? "?", "request_id": response.requestId ?? "?"]
            if Self.logsWords {
                answered["student_said"] = response.transcript ?? ""
                answered["tutor_said"] = response.answerText
            }
            env.log.record("ask_answered", answered)
            if stopped {
                env.log.record("speech_skipped", ["purpose": "answer", "reason": "screen_closed"])
            } else {
                setStatus(response.answerText, seconds: 20)
                env.speech.speak(response.answerText, purpose: "answer")
                if problem.isPractice { lesson?.noteExchange(student: response.transcript, tutor: response.answerText) }
            }
        } catch {
            reportAskError(error)
        }
        askInFlight = false
        isBusy = lookInFlight
    }

    private func reportAskError(_ error: Error) {
        noteIfPracticeExpired(error)
        let (student, detail) = TutorError.describe(error)
        env.log.record("error", ["where": "ask", "detail": detail])
        setStatus(student)
    }

    // MARK: - Practice problems (teach mode)

    /// What a question about a practice problem carries besides the page: the sealed reference, whether the student has really
    /// started (judged against the last look, and told to the lesson and to the live voice if it changed), and the last 8 turns of
    /// the lesson conversation. All nil for a bank or own problem.
    struct PracticeFields: Equatable {
        var problemRef: String?
        var attempted: Bool?
        var recent: [ConsultTurnWire]?
    }

    func practiceFields(for drawing: PKDrawing) -> PracticeFields {
        guard problem.isPractice else { return PracticeFields() }
        let attempted = attempts.attempted(Self.inkStrokes(from: drawing))
        noteAttempted(attempted, source: "request")
        let turns = lesson?.recent ?? []
        return PracticeFields(problemRef: problem.problemRef, attempted: attempted, recent: turns.isEmpty ? nil : turns)
    }

    /// Records a change of "attempted", tells the lesson (so follow-ups carry it) and pushes the matching line into the live voice.
    private func noteAttempted(_ attempted: Bool, source: String) {
        guard attemptedNow != attempted else { return }
        let first = attemptedNow == nil
        attemptedNow = attempted
        lesson?.notePracticeAttempted(attempted)
        // The first judgement is "not yet" on a page nobody has written on: nothing changed, so nothing to log or push.
        if first && !attempted { return }
        env.log.record("attempt_changed", [
            "attempted": attempted, "source": source, "work_lines": attempts.workLinesAtLastLook, "problem_id": problem.id
        ])
        if let live { pushPracticeContext(to: live, label: attempted ? "practice_attempted" : "practice_not_attempted") }
    }

    /// The rule for a practice problem, into the live voice: on connect (always "not yet" or the current state) and on every change.
    private func pushPracticeContext(to session: LiveVoice, label: String) {
        guard problem.isPractice else { return }
        session.pushContext(LiveContext.practice(attempted: attemptedNow ?? false), label: label)
    }

    /// `practice_expired` from watch, ask or consult: the sealed reference is too old. Never retried quietly (that would drop the
    /// answer guard); the screen offers a new practice problem.
    private func noteIfPracticeExpired(_ error: Error) {
        guard case .some(.practiceExpired) = error as? TutorError, !practiceExpired else { return }
        practiceExpired = true
        env.log.record("practice_expired", ["problem_id": problem.id])
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
