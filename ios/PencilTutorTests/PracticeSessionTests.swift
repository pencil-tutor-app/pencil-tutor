import PencilKit
import XCTest
@testable import PencilTutor

/// The practice page of "Learn something new" on a real canvas with a fake tutor: what the requests carry, when the student counts
/// as having started, what the live voice is told, and what happens when the reference times out. Blank, partial, written, erased
/// and crossed-out pages are all exercised here, because the answer guard depends on this flag.
@MainActor
final class PracticeSessionTests: XCTestCase {
    private var directory: URL!
    private var log: SessionLog!
    private var client: FakeTutorClient!
    private var teach: FakeTeachClient!
    private var session: TutorSession!
    private var env: AppEnvironment!
    private var canvas: PKCanvasView!
    private var transport: FakeLiveTransport!
    private var lesson: LessonSession?
    private let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let practice = Problem.practice(courseSlug: "bc-math-9-unit-3", promptPlain: "Solve 3x + 2 = 14", ref: "sealed-ref-1")

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("practice-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = SessionLog(directory: directory)
        client = FakeTutorClient()
        teach = FakeTeachClient()
    }

    override func tearDown() async throws {
        session?.stop()
        session = nil
        lesson?.stop()
        lesson = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private func makeSession(problem: Problem? = nil, live: Bool = false, withLesson: Bool = false) async {
        transport = FakeLiveTransport()
        let liveTransport = transport!
        var factory: (@MainActor () -> LiveTransport)?
        if live { factory = { liveTransport } }
        env = AppEnvironment(forTesting: client, log: log, livePlan: live, makeLiveTransport: factory)
        env.settings.idleSeconds = 3600
        if withLesson { lesson = LessonSession(courseSlug: "bc-math-9-unit-3", concept: "solving equations", env: env) }
        session = TutorSession(problem: problem ?? practice, env: env, lesson: lesson)
        canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 1180, height: 820))
        session.attach(canvas: canvas)
        if live {
            session.begin()
            await waitUntil("the live voice connects") { self.session.voice == .live(micOn: true) }
        }
    }

    private func penStroke(x: CGFloat, y: CGFloat, at seconds: TimeInterval, width: CGFloat = 20, steps: Int = 12) -> PKStroke {
        var points: [PKStrokePoint] = []
        for step in 0..<steps {
            points.append(PKStrokePoint(location: CGPoint(x: x + CGFloat(step) * width, y: y + CGFloat(step % 3) * 6),
                                        timeOffset: Double(step) * 0.01, size: CGSize(width: 4, height: 4),
                                        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
        }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: points, creationDate: epoch.addingTimeInterval(seconds)))
    }

    /// A line of work: four strokes side by side, each about 220 points wide.
    private func workLine(y: CGFloat, from seconds: TimeInterval = 1) -> [PKStroke] {
        (0..<4).map { penStroke(x: 3100 + CGFloat($0) * 240, y: y, at: seconds + Double($0)) }
    }

    /// A long flat stroke through the middle of a line of work.
    private func strike(y: CGFloat) -> PKStroke {
        var points: [PKStrokePoint] = []
        for step in 0..<20 {
            points.append(PKStrokePoint(location: CGPoint(x: 3090 + CGFloat(step) * 50, y: y + 7), timeOffset: Double(step) * 0.01,
                                        size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: epoch.addingTimeInterval(90)))
    }

    private func setPage(_ strokes: [PKStroke]) {
        canvas.drawing = PKDrawing(strokes: strokes)
        session.drawingDidChange()
    }

    private func look() async {
        let before = client.watchRequests.count
        session.checkMyWork()
        await waitUntil("the look finishes") { self.client.watchRequests.count > before && !self.session.isBusy }
    }

    private func attempted() -> Bool? { session.practiceFields(for: canvas.drawing).attempted }

    private func logRecords(_ type: String) -> [[String: Any]] {
        _ = log.exportURL()
        let text = (try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { ($0["type"] as? String) == type }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    // MARK: - What the requests carry

    func testAPracticeLookCarriesTheReferenceAndTheStatementAndIsLoggedAsTeach() async throws {
        await makeSession()
        setPage(workLine(y: 3100))
        await look()
        XCTAssertEqual(client.watchRequests.last?.problemRef, "sealed-ref-1")
        XCTAssertEqual(client.watchRequests.last?.problemId, "own:bc-math-9-unit-3")
        XCTAssertEqual(client.watchRequests.last?.problemText, "Solve 3x + 2 = 14")
        XCTAssertEqual(logRecords("problem_opened").first?["kind"] as? String, "teach")
    }

    func testABankProblemAndAnOwnProblemCarryNoReferenceAndNoAttemptedFlag() async throws {
        for problem in [Problem(id: "u3-01", promptPlain: "7x - 4 = 3x + 16"), Problem.own(courseSlug: "bc-math-9-unit-3", text: "7x - 4 = 3x + 16")] {
            client = FakeTutorClient()
            await makeSession(problem: problem)
            setPage(workLine(y: 3100))
            await look()
            XCTAssertNil(client.watchRequests.last?.problemRef)
            XCTAssertEqual(session.practiceFields(for: canvas.drawing), TutorSession.PracticeFields(), "nothing is added to an ask or consult")
            session.stop()
        }
    }

    // MARK: - The attempted rule on a real canvas

    func testABlankPageIsNotAttempted() async {
        await makeSession()
        XCTAssertEqual(attempted(), false)
        session.checkMyWork()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(attempted(), false)
        XCTAssertEqual(logRecords("look_skipped").last?["why"] as? String, "no ink on the page")
    }

    func testPartialWorkIsNotAttemptedEvenAfterLooks() async {
        await makeSession()
        setPage([penStroke(x: 3100, y: 3100, at: 1), penStroke(x: 3340, y: 3100, at: 2)])
        await look()
        await look()
        XCTAssertEqual(attempted(), false, "two strokes are not a finished line")
    }

    func testAFinishedLineCountsOnlyAfterItSurvivedALookAndNotAfterAnEdit() async {
        await makeSession(withLesson: true)
        setPage(workLine(y: 3100))
        XCTAssertEqual(attempted(), false, "just written, no look yet")
        await look()
        XCTAssertEqual(attempted(), true, "unchanged across one look")
        XCTAssertEqual(lesson?.practiceAttempted, true, "the lesson is told, so follow-ups carry it")

        setPage(workLine(y: 3100) + [penStroke(x: 4100, y: 3100, at: 50)])
        XCTAssertEqual(attempted(), false, "a stroke added since the look: not settled")
        await look()
        XCTAssertEqual(attempted(), true)
        XCTAssertEqual(logRecords("attempt_changed").map { $0["attempted"] as? Bool }, [true, false, true])
    }

    func testErasingTheWorkTakesTheAttemptBack() async {
        await makeSession(withLesson: true)
        setPage(workLine(y: 3100))
        await look()
        XCTAssertEqual(attempted(), true)
        setPage([])
        XCTAssertEqual(attempted(), false)
        XCTAssertEqual(lesson?.practiceAttempted, false)

        setPage(workLine(y: 3100))
        await look()
        await look()
        XCTAssertEqual(attempted(), true)
        session.erasePage()
        XCTAssertEqual(attempted(), false, "Erase page forgets what the looks saw")
        setPage(workLine(y: 3100))
        XCTAssertEqual(attempted(), false, "the same ink drawn again is new until a look sees it")
    }

    func testCrossedOutWorkIsNotAnAttempt() async {
        await makeSession()
        setPage(workLine(y: 3100) + [strike(y: 3100)])
        await look()
        await look()
        XCTAssertEqual(attempted(), false, "the whole line is struck through")
        // Work that was fine at the look and is crossed out afterwards also stops counting.
        setPage(workLine(y: 3200))
        await look()
        XCTAssertEqual(attempted(), true)
        setPage(workLine(y: 3200) + [strike(y: 3200)])
        XCTAssertEqual(attempted(), false)
    }

    // MARK: - The conversation on the practice page

    func testAnAskOnThePracticePageCarriesTheLessonsLastTurns() async {
        await makeSession(withLesson: true)
        for number in 1...5 { lesson?.noteExchange(student: "q\(number)", tutor: "a\(number)") }
        let fields = session.practiceFields(for: canvas.drawing)
        XCTAssertEqual(fields.problemRef, "sealed-ref-1")
        XCTAssertEqual(fields.attempted, false)
        XCTAssertEqual(fields.recent?.count, 8)
        XCTAssertEqual(fields.recent?.first?.text, "q2")
        XCTAssertEqual(fields.recent?.last?.text, "a5")
    }

    func testWithNoEarlierTurnsRecentIsLeftOut() async {
        await makeSession(withLesson: true)
        XCTAssertNil(session.practiceFields(for: canvas.drawing).recent)
    }

    // MARK: - The live voice

    func testTheLiveVoiceIsToldTheStudentHasNotTriedAndThenWhenTheyHave() async throws {
        await makeSession(live: true, withLesson: true)
        XCTAssertEqual(client.liveSessionRequests.first?.problemRef, "sealed-ref-1", "the server learns this is a practice problem")
        XCTAssertEqual(client.liveSessionRequests.first?.problemText, "Solve 3x + 2 = 14")
        func context() -> [String] { transport.sent(ofType: "session.thinking.append").compactMap { $0["content"] as? String } }
        await waitUntil("the opening rule reaches the voice") { context().contains { $0.contains("has not tried the practice problem yet") } }
        XCTAssertTrue(context().first { $0.contains("has not tried") }?.contains("Do not state the final answer") ?? false)

        setPage(workLine(y: 3100))
        await look()
        await look()
        XCTAssertEqual(attempted(), true)
        await waitUntil("the voice hears the student has written work") { context().contains { $0.contains("has now written real work") } }

        session.erasePage()
        await waitUntil("and hears it again when the page is erased") { context().filter { $0.contains("has not tried") }.count == 2 }
        XCTAssertEqual(logRecords("live_context_pushed").filter { ($0["label"] as? String)?.hasPrefix("practice_") == true }.count, 3)
    }

    func testAPageReportAskedByTheLiveVoiceCarriesTheReferenceAndAttempted() async throws {
        await makeSession(live: true)
        setPage(workLine(y: 3100))
        transport.deliver(#"{"type":"session.input_transcript.delta","delta":"What is the answer?"}"#)
        transport.deliver(#"{"type":"session.delegation.created","delegation":{"id":"item_1","type":"delegation","target":"client"}}"#)
        await waitUntil("the page report is requested") { !self.client.consultRequests.isEmpty }
        let request = try XCTUnwrap(client.consultRequests.first)
        XCTAssertEqual(request.problemRef, "sealed-ref-1")
        XCTAssertEqual(request.attempted, false, "written a moment ago and never looked at: not yet")
        XCTAssertEqual(request.problemText, "Solve 3x + 2 = 14")
    }

    func testABankProblemGetsNoPracticeContextInTheLiveVoice() async throws {
        await makeSession(problem: Problem(id: "u3-01", promptPlain: "7x - 4 = 3x + 16"), live: true)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let context = transport.sent(ofType: "session.thinking.append").compactMap { $0["content"] as? String }
        XCTAssertFalse(context.contains { $0.contains("practice problem") })
    }

    // MARK: - Expiry

    func testAnExpiredReferenceOffersANewPracticeProblemAndNeverFallsBackQuietly() async throws {
        await makeSession(withLesson: true)
        XCTAssertFalse(session.practiceExpired)
        client.failLooks(with: TutorError.practiceExpired)
        setPage(workLine(y: 3100))
        let before = client.watchRequests.count
        session.checkMyWork()
        await waitUntil("the look fails") { self.client.watchRequests.count > before && !self.session.isBusy }
        XCTAssertTrue(session.practiceExpired, "the screen shows its New practice problem button")
        XCTAssertEqual(logRecords("practice_expired").count, 1)
        XCTAssertEqual(client.watchRequests.last?.problemRef, "sealed-ref-1", "the request still carried the reference; the app did not drop it")
        XCTAssertEqual(session.statusMessage, "This practice problem has timed out. Tap New practice problem.")
    }
}
