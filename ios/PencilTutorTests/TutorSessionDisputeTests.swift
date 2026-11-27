import PencilKit
import XCTest
@testable import PencilTutor

/// A tutor client the test steers: it records every request, answers watch looks from a closure and can hold a consult until released.
/// Not main-actor bound (the client protocol is called from anywhere), so its state sits behind a lock.
final class FakeTutorClient: TutorClient, @unchecked Sendable {
    private let lock = NSLock()
    private var watches: [WatchRequest] = []
    private var consults: [ConsultRequest] = []
    private var liveSessions: [LiveSessionRequest] = []
    private var holding = false
    private var watchAnswerStore: (WatchRequest) -> WatchResponse = { FakeTutorClient.wait($0) }

    var watchRequests: [WatchRequest] { locked { watches } }
    var consultRequests: [ConsultRequest] { locked { consults } }
    var liveSessionRequests: [LiveSessionRequest] { locked { liveSessions } }

    /// What a look is answered with. Default: wait.
    func answerLooks(_ answer: @escaping (WatchRequest) -> WatchResponse) { locked { watchAnswerStore = answer } }
    /// While held, a consult does not return.
    func holdConsults(_ hold: Bool) { locked { holding = hold } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    static func wait(_ request: WatchRequest) -> WatchResponse {
        WatchResponse(action: "wait", line: nil, reason: "fake: nothing to flag", hintSpoken: nil, hintWritten: nil,
                      drawingRevision: request.drawingRevision, requestId: "fake-wait", model: "fake-model", latencyMs: 1)
    }

    static func interrupt(line: Int, _ request: WatchRequest, requestID: String = "fake-req") -> WatchResponse {
        WatchResponse(action: "interrupt", line: line, reason: "fake: planted", hintSpoken: "Take another look at line \(line).",
                      hintWritten: "Check line \(line)", drawingRevision: request.drawingRevision, requestId: requestID,
                      model: "fake-model", latencyMs: 1)
    }

    func watch(_ request: WatchRequest) async throws -> WatchResponse {
        let answer: (WatchRequest) -> WatchResponse = locked { watches.append(request); return watchAnswerStore }
        return answer(request)
    }

    func ask(_ request: AskRequest) async throws -> AskResponse {
        AskResponse(transcript: nil, answerText: "fake answer", requestId: "fake-ask", model: "fake-model", latencyMs: 1)
    }

    func consult(_ request: ConsultRequest) async throws -> ConsultResponse {
        locked { consults.append(request) }
        while locked({ holding }) { try? await Task.sleep(nanoseconds: 10_000_000) }
        return ConsultResponse(answerText: "Line two has a sign slip.", drawingRevision: request.drawingRevision,
                               requestId: "fake-consult", model: "fake-model", latencyMs: 1)
    }

    func createLiveSession(_ request: LiveSessionRequest) async throws -> LiveSessionResponse {
        locked { liveSessions.append(request) }
        return LiveSessionResponse(sessionId: "live_test", sdp: "v=0\r\nANSWER", model: "gpt-live-1", voice: "gleam", latencyMs: 1, requestId: "fake-live")
    }

    func me() async throws -> MeResponse {
        MeResponse(plan: PlanInfo(live: true, capMinutes: 480), allowance: ScriptedTutorClient.allowance, requestId: "fake-me")
    }

    func heartbeat(_ request: HeartbeatRequest) async throws -> HeartbeatResponse {
        HeartbeatResponse(ok: true, allowance: ScriptedTutorClient.allowance, requestId: "fake-heartbeat")
    }
}

/// The whole path on a real canvas with a fake tutor: look, circle, "Not a mistake", then more looks. These are the reviewer's
/// traps (docs/own-problem-plan.review.md section 5): the dispute must hold after many looks, after a line is written above,
/// and after a page re-anchor, must end on a real edit, and the voice must not say a dismissed hint.
@MainActor
final class TutorSessionDisputeTests: XCTestCase {
    private var directory: URL!
    private var log: SessionLog!
    private var client: FakeTutorClient!
    private var session: TutorSession!
    private var env: AppEnvironment!
    private var canvas: PKCanvasView!
    private var transport: FakeLiveTransport!
    private let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var clock = 10.0

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("dispute-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = SessionLog(directory: directory)
        client = FakeTutorClient()
    }

    override func tearDown() async throws {
        session?.stop()
        session = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    /// A session on a 1180 x 820 canvas. `live` opens a live voice over a fake transport (and waits until it is connected).
    private func makeSession(problem: Problem = Problem(id: "u3-01", promptPlain: "7x - 4 = 3x + 16"), live: Bool = false) async {
        transport = FakeLiveTransport()
        let liveTransport = transport!
        var factory: (@MainActor () -> LiveTransport)?
        if live { factory = { liveTransport } }
        env = AppEnvironment(forTesting: client, log: log, livePlan: live, makeLiveTransport: factory)
        // No idle looks while a test runs: every look here is one the test asked for.
        env.settings.idleSeconds = 3600
        session = TutorSession(problem: problem, env: env)
        canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 1180, height: 820))
        session.attach(canvas: canvas)
        if live {
            session.begin()
            await waitUntil("the live voice connects") { self.session.voice == .live(micOn: true) }
        }
    }

    private func penStroke(x: CGFloat, y: CGFloat, at seconds: TimeInterval) -> PKStroke {
        var points: [PKStrokePoint] = []
        for step in 0..<12 {
            points.append(PKStrokePoint(location: CGPoint(x: x + CGFloat(step) * 20, y: y + CGFloat(step % 3) * 6),
                                        timeOffset: Double(step) * 0.01, size: CGSize(width: 4, height: 4),
                                        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
        }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: points, creationDate: epoch.addingTimeInterval(seconds)))
    }

    /// Three lines of work: line 1 one stroke, line 2 two strokes (so a real edit can leave part of it), line 3 one stroke.
    private func threeLinePage(x: CGFloat = 3100) -> [PKStroke] {
        [penStroke(x: x, y: 3100, at: 1), penStroke(x: x, y: 3200, at: 2), penStroke(x: x + 240, y: 3200, at: 3),
         penStroke(x: x, y: 3300, at: 4)]
    }

    /// Puts `strokes` on the page and tells the session, as the canvas delegate does after the student writes.
    private func setPage(_ strokes: [PKStroke]) {
        canvas.drawing = PKDrawing(strokes: strokes)
        session.drawingDidChange()
    }

    private func page() -> [PKStroke] { canvas.drawing.strokes }

    private func newStrokeTime() -> TimeInterval {
        clock += 1
        return clock
    }

    /// The number the tutor would see for ink right now (the fake answers by ink, so a test does not hard-code numbers that move).
    private func lineNumber(of ink: InkIdentity) -> Int? {
        let strokes = TutorSession.inkStrokes(from: canvas.drawing)
        return LineGrouper().group(strokes).first { InkIdentity(line: $0, in: strokes).isSameInk(as: ink) }?.index
    }

    /// Presses Check my work and waits until that look is finished.
    private func look(line: @autoclosure () -> Int?) async {
        let flagged = line()
        client.answerLooks { request in
            guard let flagged else { return FakeTutorClient.wait(request) }
            return FakeTutorClient.interrupt(line: flagged, request, requestID: "req-\(request.drawingRevision)-\(flagged)")
        }
        let before = client.watchRequests.count
        session.checkMyWork()
        await waitUntil("the look at the tutor finishes") { self.client.watchRequests.count > before && !self.session.isBusy }
    }

    private func logRecords(_ type: String) -> [[String: Any]] {
        _ = log.exportURL()   // waits for pending writes
        let text = (try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { ($0["type"] as? String) == type }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    /// Circles line 2, then dismisses it. Returns the ink that was dismissed.
    private func circleLineTwoAndDismissIt(pageX: CGFloat = 3100) async throws -> InkIdentity {
        setPage(threeLinePage(x: pageX))
        await look(line: 2)
        let mark = try XCTUnwrap(session.marks.first, "the tutor should have circled line 2")
        XCTAssertEqual(mark.lineIndex, 2)
        XCTAssertEqual(mark.model, "fake-model")
        session.markNotAMistake(mark.id)
        XCTAssertTrue(session.marks.isEmpty, "the circle comes off at once")
        return mark.inkIdentity
    }

    // MARK: - The dispute itself

    func testNotAMistakeRemovesTheMarkLogsItAndTellsTheServerInTheHistory() async throws {
        await makeSession()
        setPage(threeLinePage())
        await look(line: 2)
        let mark = try XCTUnwrap(session.marks.first)

        session.markNotAMistake(mark.id)

        XCTAssertTrue(session.marks.isEmpty)
        let record = try XCTUnwrap(logRecords("mark_disputed").first)
        XCTAssertEqual(record["line"] as? Int, 2)
        XCTAssertEqual(record["request_id"] as? String, mark.requestID)
        XCTAssertEqual(record["model"] as? String, "fake-model")
        XCTAssertNil(record["hint"], "no text in the log")
        XCTAssertNil(record["hint_written"])

        await look(line: nil)
        let history = try XCTUnwrap(client.watchRequests.last?.history)
        XCTAssertEqual(history.suffix(2).map(\.action), ["interrupt", "disputed"])
        XCTAssertEqual(history.last?.line, 2)
        XCTAssertNil(history.last?.hintWritten)

        session.markNotAMistake(mark.id)
        XCTAssertEqual(logRecords("mark_dispute_ignored").count, 1, "a second tap on a mark that is gone is logged and does nothing")
    }

    func testTheSameInkIsNotCircledAgainAfterTwelveMoreLooks() async throws {
        await makeSession()
        _ = try await circleLineTwoAndDismissIt()

        for _ in 0..<12 { await look(line: 2) }

        XCTAssertTrue(session.marks.isEmpty, "twelve looks later it is still not circled")
        let suppressed = logRecords("interrupt_suppressed_disputed")
        XCTAssertEqual(suppressed.count, 12)
        XCTAssertEqual(suppressed.first?["disputed_line"] as? Int, 2)
        XCTAssertNotNil(suppressed.first?["request_id"], "the answer that was suppressed is named")
        XCTAssertNil(suppressed.first?["hint_written"], "labels and ids only")
    }

    func testTheSameInkIsNotCircledAgainAfterALineIsWrittenAboveItAndTheNumbersChange() async throws {
        await makeSession()
        let disputed = try await circleLineTwoAndDismissIt()

        setPage(page() + [penStroke(x: 3100, y: 3000, at: newStrokeTime())])
        let now = try XCTUnwrap(lineNumber(of: disputed))
        XCTAssertEqual(now, 3, "the disputed line is line 3 now, not 2")

        await look(line: now)
        XCTAssertTrue(session.marks.isEmpty)
        XCTAssertEqual(logRecords("interrupt_suppressed_disputed").count, 1)

        // The dismissal covered that ink only: a mistake the tutor finds on the new line above is still shown.
        await look(line: 1)
        XCTAssertEqual(session.marks.map(\.lineIndex), [1])
    }

    func testTheSameInkIsNotCircledAgainAfterThePageIsReanchored() async throws {
        await makeSession()
        // The page starts well left of the first screen (so the picture still holds every line after the move).
        let disputed = try await circleLineTwoAndDismissIt(pageX: 1300)
        let boundsBefore = page()[1].renderBounds

        // Ink within a screen width of the page's left edge makes the page re-anchor: every stroke moves right.
        setPage(page() + [penStroke(x: 1100, y: 3000, at: newStrokeTime())])
        XCTAssertEqual(logRecords("page_reanchored").count, 1, "the page was re-anchored")
        let boundsAfter = page()[1].renderBounds
        XCTAssertGreaterThan(boundsAfter.minX - boundsBefore.minX, 1000, "and the disputed ink moved with it by \(boundsAfter.minX - boundsBefore.minX)")

        let now = try XCTUnwrap(lineNumber(of: disputed), "the same strokes are found again after the move")
        await look(line: now)
        XCTAssertTrue(session.marks.isEmpty, "still dismissed after the page moved under it")
        XCTAssertEqual(logRecords("interrupt_suppressed_disputed").count, 1,
                       "errors: \(logRecords("error").map { String(describing: $0["detail"]) })")
    }

    func testARealEditToTheDisputedLineEndsTheDispute() async throws {
        await makeSession()
        let disputed = try await circleLineTwoAndDismissIt()

        // Erase the second stroke of line 2 (a real edit): the dispute ends, and says so.
        setPage(page().filter { $0.path.creationDate != epoch.addingTimeInterval(3) })
        XCTAssertEqual(logRecords("disputes_ended").count, 1)
        XCTAssertNil(lineNumber(of: disputed), "that ink is not on the page any more")

        // Rewrite it: new strokes, new ink. A mistake there is circled again.
        setPage(page() + [penStroke(x: 3340, y: 3200, at: newStrokeTime())])
        await look(line: 2)
        XCTAssertEqual(session.marks.map(\.lineIndex), [2], "the rewritten line is checked afresh")
        XCTAssertTrue(logRecords("interrupt_suppressed_disputed").isEmpty)
    }

    func testAddingAStrokeToTheDisputedLineIsAlsoANewLineForTheTutor() async throws {
        await makeSession()
        _ = try await circleLineTwoAndDismissIt()

        setPage(page() + [penStroke(x: 3580, y: 3200, at: newStrokeTime())])   // extends line 2 to the right
        await look(line: 2)

        XCTAssertEqual(session.marks.map(\.lineIndex), [2], "an extended line is different ink")
    }

    func testAManualLookOnlyHasTheDismissedLineToSayAnswersLooksGood() async throws {
        await makeSession()
        _ = try await circleLineTwoAndDismissIt()
        await look(line: 2)
        XCTAssertEqual(session.statusMessage, LiveContext.checkLooksGood, "the student pressed Check my work: silence would read as broken")
    }

    func testErasingThePageForgetsTheDisputes() async throws {
        await makeSession()
        _ = try await circleLineTwoAndDismissIt()
        session.erasePage()
        XCTAssertEqual(logRecords("disputes_ended").first?["why"] as? String, "page_erased")
    }

    // MARK: - problem_text on real requests

    func testTheLookCarriesTheTypedStatementForAnOwnProblemAndNothingForABankProblem() async throws {
        await makeSession(problem: Problem.own(courseSlug: "bc-math-9-unit-3", text: "7x - 4 = 3x + 16"))
        setPage(threeLinePage())
        await look(line: nil)
        XCTAssertEqual(client.watchRequests.last?.problemId, "own:bc-math-9-unit-3")
        XCTAssertEqual(client.watchRequests.last?.problemText, "7x - 4 = 3x + 16")
        XCTAssertEqual(logRecords("problem_opened").first?["kind"] as? String, "own")

        session.stop()
        client = FakeTutorClient()
        await makeSession()
        setPage(threeLinePage())
        await look(line: nil)
        XCTAssertNil(client.watchRequests.last?.problemText)
    }

    // MARK: - The voice

    func testDismissingTheCircleStopsTheHintThatIsBeingSpokenOnTheBaseVoice() async throws {
        await makeSession()
        setPage(threeLinePage())
        await look(line: 2)
        let mark = try XCTUnwrap(session.marks.first)
        XCTAssertEqual(env.speech.speakingPurpose, "hint", "the hint is being said on the base voice")

        session.markNotAMistake(mark.id)

        XCTAssertNil(env.speech.speakingPurpose, "dismissing stops it")
        XCTAssertEqual(logRecords("speech_stopped").last?["reason"] as? String, "hint_disputed")
        XCTAssertEqual(logRecords("hint_taken_back").last?["paths"] as? String, "base_voice_stopped")
    }

    func testDismissingAnOlderCircleDoesNotCutOffTheNewerHint() async throws {
        await makeSession()
        setPage(threeLinePage())
        await look(line: 2)
        let first = try XCTUnwrap(session.marks.first)
        await look(line: 3)
        XCTAssertEqual(session.marks.count, 2)
        XCTAssertEqual(env.speech.speakingPurpose, "hint", "the second hint is being said")

        session.markNotAMistake(first.id)

        XCTAssertEqual(env.speech.speakingPurpose, "hint", "the second circle's hint goes on")
        let taken = try XCTUnwrap(logRecords("hint_taken_back").last)
        XCTAssertEqual(taken["voice_still_had_this_hint"] as? Bool, false)
        XCTAssertEqual(taken["paths"] as? String, "nothing_pending")
    }

    func testAHintAlreadySentToTheLiveVoiceCannotBeRecalledSoTheVoiceIsToldNotToRepeatIt() async throws {
        await makeSession(live: true)
        setPage(threeLinePage())
        await look(line: 2)
        let mark = try XCTUnwrap(session.marks.first)
        let hints = transport.sent(ofType: "session.commentary.append").compactMap { $0["content"] as? String }.filter { $0.contains("line 2") }
        XCTAssertEqual(hints.count, 1, "the hint went out to the live voice")

        session.markNotAMistake(mark.id)

        let context = transport.sent(ofType: "session.thinking.append").compactMap { $0["content"] as? String }
        XCTAssertTrue(context.contains { $0.contains("marked line 2 as not a mistake") && $0.contains("Do not repeat") },
                      "the voice is told, quietly, that line 2 is not a mistake")
        XCTAssertEqual(logRecords("live_hint_retract_after_send").count, 1)
        let paths = try XCTUnwrap(logRecords("hint_taken_back").last?["paths"] as? String)
        XCTAssertTrue(paths.hasPrefix("sent_"), "labelled as sent, context only: \(paths)")
        XCTAssertEqual(client.liveSessionRequests.count, 1)
    }

    func testAHintHeldBehindAPageReportIsDroppedAndTheLateReportCarriesANote() async throws {
        await makeSession(problem: Problem.own(courseSlug: "bc-math-9-unit-3", text: "7x - 4 = 3x + 16"), live: true)
        XCTAssertEqual(client.liveSessionRequests.first?.problemText, "7x - 4 = 3x + 16", "the live session knows the typed problem")
        setPage(threeLinePage())
        client.holdConsults(true)

        // The student asks about the page; the page report is being read.
        transport.deliver(#"{"type":"session.input_transcript.delta","delta":"Is my second line right?"}"#)
        transport.deliver(#"{"type":"session.delegation.created","delegation":{"id":"item_9","type":"delegation","target":"client"}}"#)
        await waitUntil("the page report request is in flight") { !self.client.consultRequests.isEmpty }
        XCTAssertEqual(client.consultRequests.first?.problemText, "7x - 4 = 3x + 16")

        // The watcher circles line 2 meanwhile: its hint is held behind the report.
        await look(line: 2)
        let mark = try XCTUnwrap(session.marks.first)
        let spokenBefore = transport.sent(ofType: "session.commentary.append").compactMap { $0["content"] as? String }
        XCTAssertFalse(spokenBefore.contains { $0.contains("Take another look at line 2") }, "held, not spoken")

        // The student dismisses it, then the late report arrives.
        session.markNotAMistake(mark.id)
        XCTAssertEqual(logRecords("live_hint_dropped").last?["reason"] as? String, "disputed")
        client.holdConsults(false)
        await waitUntil("the page report goes to the live voice") {
            self.transport.sent(ofType: "session.commentary.append").contains { ($0["delegation_id"] as? String) == "item_9" }
        }

        let answer = try XCTUnwrap(transport.sent(ofType: "session.commentary.append")
            .first { ($0["delegation_id"] as? String) == "item_9" }?["content"] as? String)
        XCTAssertTrue(answer.contains("marked line 2 as not a mistake"), "the late report is marked: \(answer)")
        try? await Task.sleep(nanoseconds: 500_000_000)
        let allSpoken = transport.sent(ofType: "session.commentary.append").compactMap { $0["content"] as? String }
        XCTAssertFalse(allSpoken.contains { $0.contains("Take another look at line 2") }, "the dismissed hint is never said")
        let taken = try XCTUnwrap(logRecords("hint_taken_back").last)
        XCTAssertTrue((taken["paths"] as? String ?? "").contains("held_dropped"))
        XCTAssertTrue((taken["paths"] as? String ?? "").contains("consult_in_flight"))
        XCTAssertEqual(logRecords("live_consult_dispute_note").count, 1)
    }
}
