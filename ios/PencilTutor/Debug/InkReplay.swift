#if DEBUG
import OSLog
import PencilKit
import UIKit

/// Debug builds only; compiled out of Release. `--replay-ink <file>` writes a student's work onto the page by itself, so the
/// whole path (stroke capture, line grouping, the page picture, the watch request, the marks overlay, voice) can be tested
/// without a person holding a Pencil (`tools/handwriting/`, `docs/evals/2026-11-15-handwriting-replay.md`).
///
/// An ink script is JSON made by `tools/handwriting/ink_script.py`: lines of strokes, each stroke a list of `[x, y, t, force]`
/// with x, y in page points from the top-left of the first screen and t in seconds from the start of the script. The file is
/// looked up as an absolute path, then in the app's Documents folder, then in the app bundle (for CI).
///
/// Each scripted stroke goes through the same entry points a real one does: the canvas delegate's `canvasViewDidBeginUsingTool`
/// (pen down), then the stroke is added to the canvas's drawing as a real `PKStroke` when its scripted pen-up time arrives (the
/// canvas then calls `canvasViewDrawingDidChange` itself), then `canvasViewDidEndUsingTool` (pen up). The session's idle timer,
/// line grouping, page picture, watch request and marks all run unchanged. Only the touch itself is skipped.
///
/// Log events (counts and labels only, never the text of the work): `replay_started`, `replay_stroke_batch` (one per line),
/// `replay_finished`, `replay_screenshot`, `replay_done`, and `replay_failed` with the reason when it cannot run.
struct InkScript: Decodable {
    struct Stroke: Decodable {
        /// `[x, y, t, force]`
        let points: [[Double]]
    }

    struct Line: Decodable {
        let index: Int
        let strokes: [Stroke]
    }

    let id: String
    let lines: [Line]

    var strokeCount: Int { lines.reduce(0) { $0 + $1.strokes.count } }
    var pointCount: Int { lines.reduce(0) { $0 + $1.strokes.reduce(0) { $0 + $1.points.count } } }
}

@MainActor
enum InkReplay {
    private static let log = Logger(subsystem: "com.edwardtran.penciltutor", category: "replay")
    /// One replay per launch: the screen that was open at launch (`--open-problem`) runs it, a later screen does not.
    private static var started = false

    enum LoadError: Error, CustomStringConvertible {
        case notFound(String)
        case unreadable(String)
        case invalid(String)

        var description: String {
            switch self {
            case .notFound(let name): return "no ink script named \(name) (looked at the path, Documents and the bundle)"
            case .unreadable(let why): return "could not read the ink script: \(why)"
            case .invalid(let why): return "the ink script is not valid: \(why)"
            }
        }
    }

    // MARK: - Start

    static func startIfRequested(canvas: PKCanvasView, session: TutorSession) {
        guard let name = LaunchOptions.replayInkFile else { return }
        guard !started else {
            session.noteCanvas("replay_skipped", ["why": "a replay already ran in this launch"])
            return
        }
        started = true
        Task { @MainActor [weak canvas, weak session] in
            guard let canvas, let session else { return }
            do {
                let script = try load(named: name)
                await run(script, on: canvas, session: session)
            } catch {
                let reason = (error as? LoadError)?.description ?? String(describing: error)
                log.error("replay failed: \(reason, privacy: .public)")
                session.noteCanvas("replay_failed", ["reason": reason, "file": name])
            }
        }
    }

    // MARK: - Loading and turning a script into PencilKit strokes (pure, unit tested)

    static func load(named name: String) throws -> InkScript {
        let url: URL
        if name.hasPrefix("/") {
            url = URL(fileURLWithPath: name)
        } else if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                  FileManager.default.fileExists(atPath: documents.appendingPathComponent(name).path) {
            url = documents.appendingPathComponent(name)
        } else if let bundled = Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: "json") {
            url = bundled
        } else {
            throw LoadError.notFound(name)
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw LoadError.unreadable(String(describing: error)) }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> InkScript {
        let script: InkScript
        do { script = try JSONDecoder().decode(InkScript.self, from: data) } catch { throw LoadError.invalid(String(describing: error)) }
        guard script.strokeCount > 0 else { throw LoadError.invalid("no strokes") }
        for line in script.lines {
            for stroke in line.strokes {
                guard stroke.points.count >= 2, stroke.points.allSatisfy({ $0.count >= 4 }) else {
                    throw LoadError.invalid("line \(line.index) has a stroke with fewer than 2 points or a point without x, y, t, force")
                }
            }
        }
        return script
    }

    /// A real stroke from scripted points. Time offsets are seconds from the stroke's first point and never go backwards.
    static func makeStroke(_ stroke: InkScript.Stroke, origin: CGPoint, ink: PKInk, width: CGFloat, createdAt: Date) -> PKStroke {
        let startTime = stroke.points[0][2]
        var lastOffset: TimeInterval = 0
        let controlPoints = stroke.points.map { point -> PKStrokePoint in
            let offset = max(lastOffset, point[2] - startTime)
            lastOffset = offset
            let force = CGFloat(min(1, max(0, point[3])))
            let nib = width * (0.7 + 0.6 * force)
            return PKStrokePoint(location: CGPoint(x: origin.x + point[0], y: origin.y + point[1]), timeOffset: offset,
                                 size: CGSize(width: nib, height: nib), opacity: 1, force: force, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: controlPoints, creationDate: createdAt))
    }

    // MARK: - Running

    private static func run(_ script: InkScript, on canvas: PKCanvasView, session: TutorSession) async {
        let clock = ContinuousClock()
        let waitedFrom = clock.now
        // The page's first screen sits `homeReserve` points in from the corner; wait until the session has put it on screen.
        while clock.now - waitedFrom < .seconds(8) {
            let zoom = max(canvas.zoomScale, 0.01)
            if canvas.window != nil, canvas.bounds.width > 100, canvas.bounds.height > 100,
               abs(canvas.contentOffset.x - PageGeometry.homeReserve * zoom) < 2 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // The problem card is measured just after the first layout and home moves down to clear it; let the page hold still.
        var steadyFor = 0
        var lastOffset = canvas.contentOffset
        while steadyFor < 4, clock.now - waitedFrom < .seconds(12) {
            try? await Task.sleep(for: .milliseconds(200))
            steadyFor = canvas.contentOffset == lastOffset ? steadyFor + 1 : 0
            lastOffset = canvas.contentOffset
        }
        let waitedMs = Int((clock.now - waitedFrom) / .milliseconds(1))
        // A short beat more for the account check and the first layout, as a student would take before writing.
        try? await Task.sleep(for: .milliseconds(1000))

        let origin = CGPoint(x: PageGeometry.homeReserve, y: PageGeometry.homeReserve)
        // Always the plain black pen at the default width, whatever the rail was last set to, so every run draws the same page.
        let ink = PKInk(.pen, color: .black)
        let width: CGFloat = InkWidth.medium.penWidth
        let durationS = script.lines.last?.strokes.last?.points.last?[2] ?? 0
        session.noteCanvas("replay_started", [
            "script": script.id, "lines": script.lines.count, "strokes": script.strokeCount, "points": script.pointCount,
            "script_duration_ms": Int(durationS * 1000), "waited_ms": waitedMs,
            "canvas": "\(Int(canvas.bounds.width))x\(Int(canvas.bounds.height))", "offset": "\(Int(canvas.contentOffset.x)),\(Int(canvas.contentOffset.y))", "zoom": String(format: "%.2f", canvas.zoomScale),
            "pen": "\(ink.inkType.rawValue) \(Int(width))"
        ])

        let start = clock.now
        var maxLateMs = 0
        var drawn = 0
        for line in script.lines {
            let lineStart = clock.now
            var linePoints = 0
            for stroke in line.strokes {
                let penDownAt = stroke.points[0][2]
                let penUpAt = stroke.points[stroke.points.count - 1][2]
                await sleep(until: start + .milliseconds(Int(penDownAt * 1000)), clock: clock, lateMs: &maxLateMs)
                let createdAt = Date()
                canvas.delegate?.canvasViewDidBeginUsingTool?(canvas)
                await sleep(until: start + .milliseconds(Int(penUpAt * 1000)), clock: clock, lateMs: &maxLateMs)
                // Setting the drawing makes PencilKit call `canvasViewDrawingDidChange` itself on iPadOS 26 (checked on the iPad,
                // 2026-11-15: calling it here too doubled `ink_changed`), so it is not called by hand. The runner checks that the
                // log has one `ink_changed` per stroke and reports `delegate_not_fired` if it does not.
                canvas.drawing.append(PKDrawing(strokes: [makeStroke(stroke, origin: origin, ink: ink, width: width, createdAt: createdAt)]))
                canvas.delegate?.canvasViewDidEndUsingTool?(canvas)
                drawn += 1
                linePoints += stroke.points.count
            }
            session.noteCanvas("replay_stroke_batch", [
                "line": line.index, "strokes": line.strokes.count, "points": linePoints,
                "line_ms": Int((clock.now - lineStart) / .milliseconds(1)), "at_ms": Int((clock.now - start) / .milliseconds(1))
            ])
        }
        session.noteCanvas("replay_finished", [
            "script": script.id, "strokes_drawn": drawn, "drawing_strokes": canvas.drawing.strokes.count,
            "total_ms": Int((clock.now - start) / .milliseconds(1)), "max_late_ms": maxLateMs
        ])
        await settle(canvas: canvas, session: session, script: script)
    }

    private static func sleep(until deadline: ContinuousClock.Instant, clock: ContinuousClock, lateMs: inout Int) async {
        if deadline > clock.now {
            try? await Task.sleep(until: deadline, clock: clock)
        } else {
            lateMs = max(lateMs, Int((clock.now - deadline) / .milliseconds(1)))
        }
    }

    /// After the last stroke: give the tutor time to look and answer, then take a picture of the real screen (ink, marks, the
    /// whole window) so a person can see what the student would have seen. Ends with `replay_done`, which the runner waits for.
    private static func settle(canvas: PKCanvasView, session: TutorSession, script: InkScript) async {
        let clock = ContinuousClock()
        let from = clock.now
        let settleSeconds = LaunchOptions.replaySettleSeconds
        var markSeenAt: ContinuousClock.Instant?
        while true {
            let elapsed = clock.now - from
            if markSeenAt == nil, !session.marks.isEmpty { markSeenAt = clock.now }
            if let seen = markSeenAt, clock.now - seen > .seconds(2.5) { break }
            if elapsed > .seconds(settleSeconds), !session.isBusy { break }
            if elapsed > .seconds(settleSeconds + 90) { break }
            try? await Task.sleep(for: .milliseconds(400))
        }
        let shot = saveScreenshot(name: script.id)
        session.noteCanvas("replay_screenshot", ["file": shot ?? "none", "marks": session.marks.count])
        session.noteCanvas("replay_done", [
            "script": script.id, "marks": session.marks.count, "status": session.testStatus,
            "waited_after_ms": Int((clock.now - from) / .milliseconds(1))
        ])
    }

    /// The whole app window as a PNG in Documents, next to the session log and the page pictures.
    private static func saveScreenshot(name: String) -> String? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let png = renderer.pngData { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let safe = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let file = "screen-\(safe)-\(Int(Date().timeIntervalSince1970)).png"
        do {
            try png.write(to: documents.appendingPathComponent(file), options: .atomic)
            return file
        } catch {
            log.error("screenshot not saved: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
#endif
