import PencilKit
import XCTest
@testable import PencilTutor

/// Show me how through the real session, on a real canvas with a fake tutor and a fake live connection: what the request carries, what
/// the panel is given and when, what the live voice hears and when (nothing while it loads, never "on screen" for a refusal), the
/// spoken request on a blank page, and Try one like it. No sound: the live transport is a fake and the base voice is at volume 0.
@MainActor
final class ShowMeSessionTests: XCTestCase {
    private var directory: URL!
    private var log: SessionLog!
    private var client: FakeTutorClient!
    private var env: AppEnvironment!
    private var session: TutorSession!
    private var canvas: PKCanvasView!
    private var transport: FakeLiveTransport!

    private let statement = "Use Gaussian elimination and back-substitution: x + y + z = 6, 2x - y + z = 3, x + 2y - z = 2."
    private let steps = (1...7).map { "Row step number \($0): a line of the elimination" }
    private var bank: Problem { Problem(id: "la-02", promptPlain: statement) }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("show-me-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = SessionLog(directory: directory)
        client = FakeTutorClient()
        client.answerSolve(.success(FakeTutorClient.solved(steps: steps, finalAnswer: "(x, y, z) = (1, 2, 3)")))
    }

    override func tearDown() async throws {
        session?.stop()
        session = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private func makeSession(problem: Problem? = nil, courseSlug: String? = "linear-algebra", live: Bool = false) async {
        transport = FakeLiveTransport()
        let liveTransport = transport!
        var factory: (@MainActor () -> LiveTransport)?
        if live { factory = { liveTransport } }
        env = AppEnvironment(forTesting: client, log: log, livePlan: live, makeLiveTransport: factory)
        env.settings.idleSeconds = 3600
        session = TutorSession(problem: problem ?? bank, env: env, courseSlug: courseSlug)
        canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 1180, height: 820))
        session.attach(canvas: canvas)
        if live {
            session.begin()
            await waitUntil("the live voice connects") { self.session.voice == .live(micOn: true) }
        }
    }

    private func logRecords(_ type: String) -> [[String: Any]] {
        _ = log.exportURL()
        let text = (try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { ($0["type"] as? String) == type }
    }

    /// Every log line this feature writes, as text: to prove none of them holds the statement, a step or an answer.
    private func showMeLogText() -> String {
        _ = log.exportURL()
        let text = (try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n")
            .filter { $0.contains("\"type\":\"show_me") || $0.contains("\"type\":\"like_it") || $0.contains("\"type\":\"problem_swapped") }
            .joined(separator: "\n")
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 6, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    private func isShown() -> Bool {
        if case .shown = session.showMe.phase { return true }
        return false
    }

    private func isLoading() -> Bool { session.showMe.phase == .loading }

    private func commentary() -> [(content: String, delegation: String?)] {
        transport.sent(ofType: "session.commentary.append").map { ($0["content"] as? String ?? "", $0["delegation_id"] as? String) }
    }

    private func thinking() -> [String] {
        transport.sent(ofType: "session.thinking.append").compactMap { $0["content"] as? String }
    }

    private func sayAndDelegate(_ words: String, id: String = "item_1") {
        transport.deliver(#"{"type":"session.input_transcript.delta","delta":"\#(words)","start_ms":0,"end_ms":200}"#)
        transport.deliver(#"{"type":"session.delegation.created","delegation":{"id":"\#(id)","type":"delegation","target":"client"}}"#)
    }

    // MARK: - The button

    func testTheButtonShowsTheStoredSolutionWithEveryStepAndTheRequestCarriesTheBankIdOnly() async {
        await makeSession()
        client.holdSolves(true)
        session.showMeHow()
        await waitUntil("the panel is loading") { self.isLoading() }
        XCTAssertTrue(session.showMe.isOpen)

        client.holdSolves(false)
        await waitUntil("the steps show") { self.isShown() }
        XCTAssertEqual(session.showMe.phase, .shown(TeachSolution(steps: steps, finalAnswer: "(x, y, z) = (1, 2, 3)")), "all 7 steps, none dropped")

        let request = client.solveRequests.last
        XCTAssertEqual(request?.action, "solve")
        XCTAssertEqual(request?.course, "linear-algebra")
        XCTAssertEqual(request?.problemId, "la-02")
        XCTAssertNil(request?.problemText, "a bank problem is found by its id")
        XCTAssertNil(request?.problemRef)
        XCTAssertEqual(logRecords("show_me_requested").first?["source"] as? String, "button")
        XCTAssertEqual(logRecords("show_me_shown").first?["steps"] as? Int, 7)
        XCTAssertEqual(logRecords("show_me_shown").first?["stored"] as? Bool, true)
    }

    func testTheLogHoldsLabelsAndCountsNeverTheStatementTheStepsOrTheAnswer() async {
        await makeSession()
        session.showMeHow()
        await waitUntil("the steps show") { self.isShown() }
        session.showMe.tryOneLikeIt()
        await waitUntil("the problem is made") { !self.logRecords("like_it_ready").isEmpty }
        let text = showMeLogText()
        XCTAssertFalse(text.isEmpty)
        for secret in ["Row step number", "a line of the elimination", "(1, 2, 3)", "Gaussian", "x + y + z", "Solve 5x"] {
            XCTAssertFalse(text.contains(secret), "the show-me log must not contain: \(secret)")
        }
    }

    func testAnOwnProblemSendsItsTypedTextAndAPracticeProblemItsReferenceAndItsStatement() async {
        let own = Problem.own(courseSlug: "bc-math-9-unit-3", text: "7x - 4 = 3x + 16")
        await makeSession(problem: own, courseSlug: nil)
        session.showMeHow()
        await waitUntil("the steps show") { self.isShown() }
        XCTAssertEqual(client.solveRequests.last?.course, "bc-math-9-unit-3", "an own problem's course is in its id")
        XCTAssertEqual(client.solveRequests.last?.problemId, "own:bc-math-9-unit-3")
        XCTAssertEqual(client.solveRequests.last?.problemText, "7x - 4 = 3x + 16")
        XCTAssertNil(client.solveRequests.last?.problemRef)
        session.stop()

        let practice = Problem.practice(courseSlug: "bc-math-9-unit-3", promptPlain: "Solve 3x + 2 = 14", ref: "sealed-ref-1")
        await makeSession(problem: practice, courseSlug: nil)
        session.showMeHow()
        await waitUntil("the steps show") { self.isShown() }
        XCTAssertEqual(client.solveRequests.last?.problemRef, "sealed-ref-1")
        XCTAssertEqual(client.solveRequests.last?.problemText, "Solve 3x + 2 = 14")
        XCTAssertEqual(logRecords("show_me_requested").last?["kind"] as? String, "teach")
    }

    func testClosingAndOpeningAgainShowsTheSameSolutionWithoutAskingAgain() async {
        await makeSession()
        session.showMeHow()
        await waitUntil("the steps show") { self.isShown() }
        session.showMe.close()
        XCTAssertEqual(session.showMe.phase, .closed)
        session.showMeHow()
        await waitUntil("the steps show again") { self.isShown() }
        XCTAssertEqual(client.solveRequests.count, 1, "no second model call for the same page")
        XCTAssertEqual(logRecords("show_me_reopened").count, 1)
    }

    func testNotCheckedAndFailedAreTheirOwnStatesTheNextTryIsFreshAndNothingUncheckedIsShown() async {
        await makeSession()
        client.answerSolve(.success(FakeTutorClient.notChecked()))
        session.showMeHow()
        await waitUntil("not checked") { self.session.showMe.phase == .notChecked }
        XCTAssertEqual(logRecords("show_me_not_checked").first?["reason"] as? String, "not_checked")

        client.answerSolve(.failure(TutorError.timedOut))
        session.showMeHow()
        await waitUntil("failed") { if case .failed = self.session.showMe.phase { return true } else { return false } }

        client.answerSolve(.success(FakeTutorClient.solved(steps: steps, finalAnswer: "(x, y, z) = (1, 2, 3)")))
        session.showMeHow()
        await waitUntil("the steps show") { self.isShown() }
        XCTAssertEqual(client.solveRequests.count, 3, "a refusal and a failure are never cached")
    }

    // MARK: - What the voice hears

    func testTheLiveVoiceHearsNothingWhileItLoadsThenTheStepsAsQuietContextAndOneWalkthroughLine() async {
        await makeSession(live: true)
        let before = commentary().count
        client.holdSolves(true)
        session.showMeHow()
        await waitUntil("loading") { self.isLoading() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(commentary().count, before, "nothing is said while the solution loads")
        XCTAssertTrue(thinking().filter { $0.contains("Row step number") }.isEmpty)

        client.holdSolves(false)
        await waitUntil("the walkthrough line") { self.commentary().contains { $0.content == LiveContext.showMeWalkthrough } }
        let parts = thinking().filter { $0.contains("Worked solution now on the student's screen") }
        XCTAssertFalse(parts.isEmpty)
        XCTAssertTrue(parts.allSatisfy { $0.count <= LiveClientEvent.maxTextCharacters })
        XCTAssertTrue(parts.joined().contains("Row step number 7"), "every step reaches the voice")
        XCTAssertEqual(commentary().filter { $0.content == LiveContext.showMeWalkthrough }.count, 1, "said once")
        let walkthrough = commentary().first { $0.content == LiveContext.showMeWalkthrough }
        XCTAssertNil(walkthrough?.delegation, "the button path is not an answer to a delegation")
        XCTAssertEqual(logRecords("show_me_voice").first?["via"] as? String, "live")
    }

    func testWithoutLiveTheBaseVoiceSaysOneShortLineOnceTheStepsShow() async {
        await makeSession()
        client.holdSolves(true)
        session.showMeHow()
        await waitUntil("loading") { self.isLoading() }
        XCTAssertTrue(logRecords("show_me_voice").isEmpty, "nothing is said while it loads")
        client.holdSolves(false)
        await waitUntil("the line is said") { !self.logRecords("show_me_voice").isEmpty }
        XCTAssertEqual(logRecords("show_me_voice").first?["via"] as? String, "speech_output")
    }

    func testASpokenRequestOnABlankPageReachesTheRouterOpensThePanelAndAnswersTheDelegationOnceAfterTheStepsShow() async {
        await makeSession(live: true)
        XCTAssertTrue(canvas.drawing.strokes.isEmpty, "the page is blank")
        client.consultAnswersShowMe(true)
        client.holdSolves(true)
        sayAndDelegate("I have no idea, show me")

        await waitUntil("the page reader is asked even though there is no ink") { self.client.consultRequests.count == 1 }
        let asked = client.consultRequests[0]
        XCTAssertEqual(asked.showMeOk, true, "only an app that can show says so")
        XCTAssertTrue(asked.question.contains("no idea"))
        XCTAssertFalse(asked.imagePngBase64.isEmpty, "a blank page is still a picture")
        XCTAssertEqual(logRecords("live_consult_blank_page").count, 1)

        await waitUntil("the panel is loading") { self.isLoading() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(commentary().filter { $0.delegation == "item_1" }.isEmpty, "the delegation waits while the steps load, and the voice says nothing")

        client.holdSolves(false)
        await waitUntil("the delegation is answered") { self.commentary().contains { $0.delegation == "item_1" } }
        XCTAssertTrue(isShown())
        let answers = commentary().filter { $0.delegation == "item_1" }
        XCTAssertEqual(answers.map { $0.content }, [LiveContext.showMeWalkthrough], "answered once, with the walkthrough")
        XCTAssertTrue(thinking().joined().contains("Row step number 1"), "the steps came first, as quiet context")
        XCTAssertEqual(logRecords("show_me_requested").first?["source"] as? String, "voice")
        XCTAssertEqual(logRecords("show_me_voice_answered").first?["outcome"] as? String, "shown")
        XCTAssertEqual(commentary().filter { $0.content == LiveContext.showMeWalkthrough }.count, 1, "no second spoken start instruction")
    }

    func testANotCheckedSolutionIsAnsweredAsThatAndNeverAsOnScreen() async {
        await makeSession(live: true)
        client.consultAnswersShowMe(true)
        client.answerSolve(.success(FakeTutorClient.notChecked()))
        sayAndDelegate("show me how")
        await waitUntil("the delegation is answered") { self.commentary().contains { $0.delegation == "item_1" } }
        XCTAssertEqual(session.showMe.phase, .notChecked)
        let answer = commentary().first { $0.delegation == "item_1" }?.content ?? ""
        XCTAssertEqual(answer, LiveContext.showMeNotChecked)
        XCTAssertFalse(answer.contains("is on the student's screen now"))
        XCTAssertTrue(thinking().filter { $0.contains("Worked solution now on the student's screen") }.isEmpty, "no steps were given to the voice")
    }

    func testAFailedSolveIsAnsweredAsFailedAndTheVoiceStillGetsOneAnswerOnly() async {
        await makeSession(live: true)
        client.consultAnswersShowMe(true)
        client.answerSolve(.failure(TutorError.offline(detail: "test")))
        sayAndDelegate("I give up, show me")
        await waitUntil("the delegation is answered") { self.commentary().contains { $0.delegation == "item_1" } }
        XCTAssertEqual(commentary().filter { $0.delegation == "item_1" }.map { $0.content }, [LiveContext.showMeFailed])
        if case .failed = session.showMe.phase {} else { XCTFail("the panel says it failed: \(session.showMe.phase)") }
    }

    func testAnOrdinaryPageReportStillGoesToTheVoiceAsWordsAndNoPanelOpens() async {
        await makeSession(live: true)
        client.consultAnswersShowMe(false)
        sayAndDelegate("is my last line right")
        await waitUntil("the report is answered") { self.commentary().contains { $0.delegation == "item_1" } }
        XCTAssertEqual(commentary().first { $0.delegation == "item_1" }?.content, "Line two has a sign slip.")
        XCTAssertEqual(session.showMe.phase, .closed)
        XCTAssertTrue(client.solveRequests.isEmpty)
        XCTAssertEqual(client.consultRequests.first?.showMeOk, true)
    }

    // MARK: - Try one like it

    func testTryOneLikeItAsksForAProblemLikeTheOneShownWithNoExampleAndHandsItToTheScreen() async {
        await makeSession()
        session.showMeHow()
        await waitUntil("the steps show") { self.isShown() }
        var swapped: Problem?
        session.showMe.onPractice = { swapped = $0 }

        session.showMe.tryOneLikeIt()
        await waitUntil("the new problem arrives") { swapped != nil }

        let request = client.practiceRequests.last
        XCTAssertEqual(request?.action, "practice", "the existing practice action")
        XCTAssertEqual(request?.course, "linear-algebra")
        XCTAssertEqual(request?.concept, ShowMeSession.likeItConcept)
        XCTAssertNil(request?.example, "what was shown is already stored or checked: nothing to recheck")
        let lesson = request?.lessonText ?? ""
        XCTAssertTrue(lesson.contains(statement), "the generator is told what to differ from")
        XCTAssertTrue(lesson.contains("1. Row step number 1"))
        XCTAssertTrue(lesson.contains("Answer: (x, y, z) = (1, 2, 3)"))
        XCTAssertLessThanOrEqual(lesson.count, LessonText.maxCharacters)

        XCTAssertEqual(swapped?.promptPlain, "Solve 5x - 3 = 2x + 9")
        XCTAssertEqual(swapped?.problemRef, "sealed-like-it")
        XCTAssertEqual(swapped?.isPractice, true, "a normal practice page: sealed reference, watched like any page")
        XCTAssertEqual(swapped?.id, "own:linear-algebra")
        XCTAssertEqual(session.showMe.next, .idle)
    }

    func testTryOneLikeItNotCheckedAndFailedSayWhyKeepTheSolutionAndOfferAnotherTry() async {
        await makeSession()
        session.showMeHow()
        await waitUntil("the steps show") { self.isShown() }
        var swapped: Problem?
        session.showMe.onPractice = { swapped = $0 }

        client.answerPractice(.success(TeachPracticeResponse(problem: nil, reason: "not_checked", problemRef: nil, exampleChecked: nil,
                                                             requestId: "r", model: "m", latencyMs: 1)))
        session.showMe.tryOneLikeIt()
        await waitUntil("not checked") { self.session.showMe.next == .notChecked }
        XCTAssertNil(swapped, "an unchecked problem is never shown")
        XCTAssertTrue(isShown(), "the solution stays")

        client.answerPractice(.failure(TutorError.timedOut))
        session.showMe.tryOneLikeIt()
        await waitUntil("failed") { if case .failed = self.session.showMe.next { return true } else { return false } }
        XCTAssertNil(swapped)

        client.answerPractice(.success(FakeTutorClient.madeProblem()))
        session.showMe.tryOneLikeIt()
        await waitUntil("the problem arrives") { swapped != nil }
        XCTAssertEqual(client.practiceRequests.count, 3)
    }

    func testTryOneLikeItDoesNothingBeforeTheStepsShow() async {
        await makeSession()
        session.showMe.tryOneLikeIt()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(client.practiceRequests.isEmpty)
        XCTAssertEqual(session.showMe.next, .idle)
    }

    func testLeavingThePageWhileTheSolutionLoadsSettlesQuietly() async {
        await makeSession(live: true)
        client.holdSolves(true)
        session.showMeHow()
        await waitUntil("loading") { self.isLoading() }
        let before = commentary().count
        session.stop()
        client.holdSolves(false)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(commentary().count, before, "a page that was left says nothing")
    }
}
