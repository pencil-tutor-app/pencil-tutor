import XCTest
@testable import PencilTutor

/// A tutor client that teaches: every teach call is steered by the test, and every request is kept. Nothing else is implemented
/// (the rest throws), which is also how a client that only knows the older calls compiles: see `testAClientWithoutTeachCallsStillCompiles`.
final class FakeTeachClient: TutorClient, @unchecked Sendable {
    private let lock = NSLock()
    private var explains: [TeachExplainRequest] = []
    private var followups: [TeachFollowupRequest] = []
    private var practices: [TeachPracticeRequest] = []
    private var explainReply: Result<TeachExplainResponse, Error> = .success(FakeTeachClient.lesson())
    private var practiceReplies: [Result<TeachPracticeResponse, Error>] = []
    private var holdingPractice = false

    var explainRequests: [TeachExplainRequest] { locked { explains } }
    var followupRequests: [TeachFollowupRequest] { locked { followups } }
    var practiceRequests: [TeachPracticeRequest] { locked { practices } }

    func answerExplain(_ reply: Result<TeachExplainResponse, Error>) { locked { explainReply = reply } }
    /// Replies for the next practice calls, in order (the last one repeats).
    func answerPractice(_ replies: [Result<TeachPracticeResponse, Error>]) { locked { practiceReplies = replies } }
    func holdPractice(_ hold: Bool) { locked { holdingPractice = hold } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    static func lesson() -> TeachExplainResponse {
        TeachExplainResponse(
            isMath: true, fitsCourse: true, message: nil,
            lesson: TeachLesson(
                title: "Undoing an operation",
                steps: ["An equation is a balance.", "Undo the last operation first.", "Check by putting x back."],
                example: TeachExample(promptPlain: "Solve 2x + 1 = 9", steps: ["2x = 8", "x = 4"], finalAnswer: "x = 4"),
                spoken: "An equation is a balance."
            ),
            requestId: "fake-explain", model: "fake-model", latencyMs: 5
        )
    }

    static func practice(exampleChecked: Bool? = true, problem: Bool = true) -> TeachPracticeResponse {
        TeachPracticeResponse(
            problem: problem ? TeachPracticeProblem(id: "own:bc-math-9-unit-3", promptPlain: "Solve 3x + 2 = 14") : nil,
            reason: problem ? nil : "not_checked", problemRef: problem ? "sealed-ref-1" : nil, exampleChecked: exampleChecked,
            requestId: "fake-practice", model: "fake-model", latencyMs: 5
        )
    }

    func teachExplain(_ request: TeachExplainRequest) async throws -> TeachExplainResponse {
        let reply = locked { () -> Result<TeachExplainResponse, Error> in explains.append(request); return explainReply }
        return try reply.get()
    }

    func teachFollowup(_ request: TeachFollowupRequest) async throws -> TeachFollowupResponse {
        locked { followups.append(request) }
        return TeachFollowupResponse(transcript: request.audioBase64 == nil ? nil : "heard", answerText: "Answer \(followupRequests.count).",
                                     requestId: "fake-followup", model: "fake-model", latencyMs: 5)
    }

    func teachPractice(_ request: TeachPracticeRequest) async throws -> TeachPracticeResponse {
        while locked({ holdingPractice }) { try? await Task.sleep(nanoseconds: 10_000_000) }
        let reply = locked { () -> Result<TeachPracticeResponse, Error> in
            practices.append(request)
            let index = min(practices.count - 1, max(0, practiceReplies.count - 1))
            return practiceReplies.isEmpty ? .success(FakeTeachClient.practice()) : practiceReplies[index]
        }
        return try reply.get()
    }

    func watch(_ request: WatchRequest) async throws -> WatchResponse { throw TutorError.notConfigured(reason: "fake") }
    func ask(_ request: AskRequest) async throws -> AskResponse { throw TutorError.notConfigured(reason: "fake") }
    func consult(_ request: ConsultRequest) async throws -> ConsultResponse { throw TutorError.notConfigured(reason: "fake") }
    func createLiveSession(_ request: LiveSessionRequest) async throws -> LiveSessionResponse { throw TutorError.notConfigured(reason: "fake") }
    func me() async throws -> MeResponse { MeResponse(plan: PlanInfo(live: false, capMinutes: 480), allowance: ScriptedTutorClient.allowance, requestId: "fake-me") }
    func heartbeat(_ request: HeartbeatRequest) async throws -> HeartbeatResponse { HeartbeatResponse(ok: true, allowance: ScriptedTutorClient.allowance, requestId: "fake-hb") }
    func memoryStatus() async throws -> MemoryStatusResponse { throw TutorError.notConfigured(reason: "fake") }
    func memoryAct(_ request: MemoryActionRequest) async throws -> MemoryActionResponse { throw TutorError.notConfigured(reason: "fake") }
}

/// The lesson's own logic with a fake tutor: what the panel is given and when, the practice problem's states, and the memory of the
/// conversation. No views and no sound (the app environment's speech is the device voice at volume 0 under XCTest).
@MainActor
final class LessonSessionTests: XCTestCase {
    private var directory: URL!
    private var log: SessionLog!
    private var client: FakeTeachClient!
    private var env: AppEnvironment!
    private var lesson: LessonSession!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lesson-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = SessionLog(directory: directory)
        client = FakeTeachClient()
        env = AppEnvironment(forTesting: client, log: log)
        lesson = LessonSession(courseSlug: "bc-math-9-unit-3", concept: "solving equations", env: env)
    }

    override func tearDown() async throws {
        lesson?.stop()
        lesson = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func logRecords(_ type: String) -> [[String: Any]] {
        _ = log.exportURL()
        let text = (try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { ($0["type"] as? String) == type }
    }

    /// 30 s, not 5: the first lesson in a test process starts the device voice (at volume 0), whose first use takes about 5 s on the
    /// main actor in a fresh simulator, and nothing else can run meanwhile.
    private func waitUntil(_ what: String, timeout: TimeInterval = 30, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    private func startAndWaitForPractice() async {
        lesson.start()
        await waitUntil("the practice problem arrives") { self.lesson.practiceState != .preparing }
    }

    // MARK: - The lesson arrives

    func testTheLessonFillsThePanelAndTheRequestNamesTheCourseAndConcept() async {
        client.holdPractice(true)
        lesson.start()
        await waitUntil("the lesson is ready") { self.lesson.phase == .ready }
        XCTAssertEqual(lesson.lesson?.title, "Undoing an operation")
        XCTAssertEqual(lesson.lesson?.steps.count, 3)
        XCTAssertEqual(client.explainRequests.first?.course, "bc-math-9-unit-3")
        XCTAssertEqual(client.explainRequests.first?.concept, "solving equations")
        let shown = try? XCTUnwrap(logRecords("lesson_shown").first)
        XCTAssertEqual(shown?["steps"] as? Int, 3)
        XCTAssertEqual(shown?["example_lines"] as? Int, 4)
        XCTAssertNotNil(shown?["latency_ms"] as? Int, "the latency is measured on the iPad, Start to panel")
        client.holdPractice(false)
    }

    func testStartingTwiceAsksOnce() async {
        lesson.start()
        lesson.start()
        await waitUntil("the lesson is ready") { self.lesson.phase == .ready }
        XCTAssertEqual(client.explainRequests.count, 1)
    }

    func testNothingOnThePanelChangesByItselfOnceTheLessonIsShown() async {
        await startAndWaitForPractice()
        let before = (lesson.lesson, lesson.turns, lesson.exampleState, lesson.practiceState)
        try? await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(lesson.phase, .ready)
        XCTAssertEqual(lesson.lesson, before.0)
        XCTAssertEqual(lesson.turns, before.1)
        XCTAssertEqual(lesson.exampleState, before.2)
        XCTAssertEqual(lesson.practiceState, before.3, "there is no timer: the panel stays until the student acts")
    }

    func testAConceptThatIsNotMathsIsRefusedInPlainWords() async {
        client.answerExplain(.success(TeachExplainResponse(isMath: false, fitsCourse: true)))
        lesson.start()
        await waitUntil("the refusal") { self.lesson.phase != .loading }
        XCTAssertEqual(lesson.phase, .refused("I can teach maths topics only."))
        XCTAssertEqual(logRecords("lesson_refused").first?["reason"] as? String, "not_math")
        XCTAssertTrue(client.practiceRequests.isEmpty, "no practice problem is made for a refused concept")
    }

    func testAConceptFromAnotherCourseIsRefusedAndNamedSo() async {
        var reply = FakeTeachClient.lesson()
        reply.fitsCourse = false
        reply.message = "That belongs to another course; pick it there."
        reply.lesson = nil
        client.answerExplain(.success(reply))
        lesson.start()
        await waitUntil("the refusal") { self.lesson.phase != .loading }
        XCTAssertEqual(lesson.phase, .refused("That belongs to another course; pick it there."))
        XCTAssertEqual(logRecords("lesson_refused").first?["reason"] as? String, "concept_outside_course")
    }

    func testTheServersOwnWordsForARefusalAreShown() async {
        client.answerExplain(.success(TeachExplainResponse(isMath: false, fitsCourse: false, message: "Words from the server.", lesson: nil)))
        lesson.start()
        await waitUntil("the refusal") { self.lesson.phase != .loading }
        XCTAssertEqual(lesson.phase, .refused("Words from the server."))
    }

    func testAReplyWithoutAStepIsAFailureNotAHalfDrawnPanel() async {
        var reply = FakeTeachClient.lesson()
        reply.lesson?.steps = []
        client.answerExplain(.success(reply))
        lesson.start()
        await waitUntil("the failure") { self.lesson.phase != .loading }
        guard case .failed = lesson.phase else { return XCTFail("expected a failure, got \(lesson.phase)") }
        XCTAssertNil(lesson.lesson)
    }

    func testALessonThatCameBackTooLongSaysSoAndTryAgainAsksAgain() async {
        client.answerExplain(.failure(TutorError.teachTooLong))
        lesson.start()
        await waitUntil("the failure") { self.lesson.phase != .loading }
        XCTAssertEqual(lesson.phase, .failed("That came out too long, try again."))
        client.answerExplain(.success(FakeTeachClient.lesson()))
        lesson.retryLesson()
        await waitUntil("the lesson") { self.lesson.phase == .ready }
        XCTAssertEqual(client.explainRequests.count, 2)
    }

    // MARK: - The example is hidden until it is checked

    func testTheExampleIsHiddenWhileItsCheckIsPendingAndShownOnceChecked() async {
        client.holdPractice(true)
        lesson.start()
        await waitUntil("the lesson is ready") { self.lesson.phase == .ready }
        XCTAssertEqual(lesson.exampleState, .pending)
        XCTAssertNil(lesson.visibleExample, "an unchecked example is never handed to the screen")
        XCTAssertFalse(lesson.canStartPractice, "Your turn waits for the practice problem")
        client.holdPractice(false)
        await waitUntil("the check result") { self.lesson.exampleState != .pending }
        XCTAssertEqual(lesson.exampleState, .checked)
        XCTAssertEqual(lesson.visibleExample?.finalAnswer, "x = 4")
    }

    func testARejectedExampleIsWithheldAndStaysWithheldEvenIfALaterCheckAcceptsIt() async {
        client.answerPractice([.success(FakeTeachClient.practice(exampleChecked: false, problem: false)),
                               .success(FakeTeachClient.practice(exampleChecked: true))])
        await startAndWaitForPractice()
        XCTAssertEqual(lesson.exampleState, .withheld)
        XCTAssertNil(lesson.visibleExample)
        XCTAssertEqual(logRecords("example_withheld").count, 1)
        lesson.tryPracticeAgain()
        await waitUntil("the second practice call") { self.lesson.practiceState == .ready }
        XCTAssertEqual(lesson.exampleState, .withheld, "a rejection is final")
        XCTAssertNil(lesson.visibleExample)
    }

    func testAnExampleTheServerDidNotAnswerForStaysHidden() async {
        client.answerPractice([.success(FakeTeachClient.practice(exampleChecked: nil))])
        await startAndWaitForPractice()
        XCTAssertEqual(lesson.exampleState, .withheld)
        XCTAssertNil(lesson.visibleExample)
    }

    func testIfThePracticeCallFailsTheExampleStaysHiddenAndSaysItWasNotChecked() async {
        client.answerPractice([.failure(TutorError.timedOut), .success(FakeTeachClient.practice())])
        await startAndWaitForPractice()
        XCTAssertEqual(lesson.exampleState, .notChecked)
        XCTAssertNil(lesson.visibleExample)
        guard case .failed = lesson.practiceState else { return XCTFail("expected a failed practice state") }
        lesson.tryPracticeAgain()
        await waitUntil("the retry") { self.lesson.practiceState == .ready }
        XCTAssertEqual(lesson.exampleState, .checked, "the retry's check can show an example that was never rejected")
    }

    func testThePanelIsGivenNoExampleTextInTheLessonSentToTheServerUntilItIsChecked() async {
        client.holdPractice(true)
        lesson.start()
        await waitUntil("the lesson is ready") { self.lesson.phase == .ready }
        lesson.ask(typed: "why undo the last one first?")
        await waitUntil("the follow-up reaches the server") { !self.client.followupRequests.isEmpty }
        XCTAssertFalse(client.followupRequests[0].lessonText.contains("Example"), "the unchecked example is not in the follow-up's lesson")
        client.holdPractice(false)
        await waitUntil("checked") { self.lesson.exampleState == .checked }
        await waitUntil("the first answer") { !self.lesson.isAnswering }
        lesson.ask(typed: "and then?")
        await waitUntil("the second follow-up") { self.client.followupRequests.count == 2 }
        XCTAssertTrue(client.followupRequests[1].lessonText.contains("Example: Solve 2x + 1 = 9"))
    }

    // MARK: - The practice problem

    func testYourTurnWaitsForTheCheckedProblemAndThatProblemCarriesItsReference() async {
        client.holdPractice(true)
        lesson.start()
        await waitUntil("the lesson is ready") { self.lesson.phase == .ready }
        XCTAssertEqual(lesson.practiceState, .preparing)
        XCTAssertFalse(lesson.canStartPractice)
        client.holdPractice(false)
        await waitUntil("the problem") { self.lesson.canStartPractice }
        let problem = try? XCTUnwrap(lesson.practiceProblem)
        XCTAssertEqual(problem?.id, "own:bc-math-9-unit-3")
        XCTAssertEqual(problem?.promptPlain, "Solve 3x + 2 = 14")
        XCTAssertEqual(problem?.problemRef, "sealed-ref-1")
        XCTAssertTrue(problem?.isPractice ?? false)
        XCTAssertEqual(problem?.kindLabel, "teach")
        XCTAssertEqual(problem?.promptParts, [.text("Solve 3x + 2 = 14")], "drawn by the same parser as every prompt")
        XCTAssertEqual(logRecords("practice_ready").first?["reference"] as? String, "checked")
    }

    func testNotCheckedOffersTryAgainAndEachTapIsOneRequest() async {
        client.answerPractice([.success(FakeTeachClient.practice(problem: false)), .success(FakeTeachClient.practice(problem: false)),
                               .success(FakeTeachClient.practice())])
        await startAndWaitForPractice()
        XCTAssertEqual(lesson.practiceState, .notChecked)
        XCTAssertNil(lesson.practiceProblem)
        XCTAssertFalse(lesson.canStartPractice, "an unchecked problem is never offered")
        XCTAssertEqual(client.practiceRequests.count, 1, "no automatic retry")
        lesson.tryPracticeAgain()
        await waitUntil("second") { self.client.practiceRequests.count == 2 && self.lesson.practiceState != .preparing }
        XCTAssertEqual(lesson.practiceState, .notChecked)
        lesson.tryPracticeAgain()
        await waitUntil("third") { self.lesson.practiceState == .ready }
        XCTAssertEqual(client.practiceRequests.count, 3)
        XCTAssertEqual(logRecords("practice_not_checked").count, 2)
    }

    func testAnExpiredPracticeProblemIsReplacedByANewOne() async {
        client.answerPractice([.success(FakeTeachClient.practice())])
        await startAndWaitForPractice()
        XCTAssertTrue(lesson.canStartPractice)
        lesson.notePracticeAttempted(true)
        lesson.newPractice(reason: "expired")
        XCTAssertFalse(lesson.canStartPractice, "the old problem is gone at once")
        XCTAssertFalse(lesson.practiceAttempted, "a new problem starts untried")
        await waitUntil("a new problem") { self.lesson.canStartPractice }
        XCTAssertEqual(client.practiceRequests.count, 2)
    }

    func testThePracticeRequestCarriesTheLessonAndTheExampleToBeChecked() async {
        await startAndWaitForPractice()
        let request = client.practiceRequests[0]
        XCTAssertEqual(request.course, "bc-math-9-unit-3")
        XCTAssertTrue(request.lessonText.hasPrefix("Undoing an operation\n1. An equation is a balance."), "the lesson as text, what the student read")
        XCTAssertLessThanOrEqual(request.lessonText.count, LessonText.maxCharacters)
        XCTAssertFalse(request.lessonText.contains("Example"), "the example travels as its own field")
        XCTAssertEqual(request.example?.finalAnswer, "x = 4", "the server checks the example the student was sent")
    }

    // MARK: - The conversation

    func testAFollowUpIsAddedToThePanelAndCarriesTheTurnsBeforeIt() async {
        await startAndWaitForPractice()
        lesson.ask(typed: "why first?")
        await waitUntil("answer 1") { self.lesson.turns.count == 2 && !self.lesson.isAnswering }
        lesson.ask(typed: "and if it is minus?")
        await waitUntil("answer 2") { self.lesson.turns.count == 4 && !self.lesson.isAnswering }
        XCTAssertEqual(lesson.turns.map(\.text), ["why first?", "Answer 1.", "and if it is minus?", "Answer 2."])
        XCTAssertEqual(client.followupRequests[0].recent, [])
        XCTAssertEqual(client.followupRequests[1].recent.map(\.text), ["why first?", "Answer 1."], "the second question sees the first exchange, in order")
        XCTAssertEqual(client.followupRequests[1].recent.map(\.role), ["student", "tutor"])
        XCTAssertEqual(client.followupRequests[1].question, "and if it is minus?")
        XCTAssertNil(client.followupRequests[1].audioBase64)
    }

    func testRecentKeepsTheLastEightTurnsInOrderEachCappedAt400() {
        for number in 1...6 {
            lesson.noteExchange(student: "q\(number)", tutor: String(repeating: "a", count: 500) + "\(number)")
        }
        XCTAssertEqual(lesson.turns.count, 12)
        let recent = lesson.recent
        XCTAssertEqual(recent.count, 8)
        XCTAssertEqual(recent.first?.text, "q3", "the oldest four turns fell off")
        XCTAssertEqual(recent.map(\.role), ["student", "tutor", "student", "tutor", "student", "tutor", "student", "tutor"])
        XCTAssertTrue(recent.allSatisfy { $0.text.count <= 400 })
        XCTAssertEqual(recent[1].text.count, 400, "a long answer is cut to 400 characters")
        XCTAssertEqual(recent.last?.text.prefix(3), "aaa")
    }

    func testABlankQuestionIsNotSent() async {
        await startAndWaitForPractice()
        lesson.ask(typed: "   \n ")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(client.followupRequests.isEmpty)
        XCTAssertTrue(lesson.turns.isEmpty)
    }

    func testFollowUpsCarryTheReferenceAndTheAttemptedFlagOnceAPracticeProblemExists() async {
        await startAndWaitForPractice()
        lesson.ask(typed: "what is the answer to my problem?")
        await waitUntil("answer") { !self.lesson.isAnswering && !self.client.followupRequests.isEmpty }
        XCTAssertEqual(client.followupRequests[0].problemRef, "sealed-ref-1")
        XCTAssertEqual(client.followupRequests[0].problemText, "Solve 3x + 2 = 14", "the statement travels with the reference")
        XCTAssertEqual(client.followupRequests[0].attempted, false, "nothing written yet")
        lesson.notePracticeAttempted(true)
        lesson.ask(typed: "is that right?")
        await waitUntil("second") { self.client.followupRequests.count == 2 }
        XCTAssertEqual(client.followupRequests[1].attempted, true)
    }

    func testBeforeAnyPracticeProblemAFollowUpCarriesNeitherReferenceNorFlag() async {
        client.holdPractice(true)
        lesson.start()
        await waitUntil("lesson") { self.lesson.phase == .ready }
        lesson.ask(typed: "why?")
        await waitUntil("request") { !self.client.followupRequests.isEmpty }
        XCTAssertNil(client.followupRequests[0].problemRef)
        XCTAssertNil(client.followupRequests[0].problemText)
        XCTAssertNil(client.followupRequests[0].attempted)
        client.holdPractice(false)
    }

    func testAnExchangeOnThePracticePageLandsInTheSamePanel() {
        lesson.noteExchange(student: "what do I do first?", tutor: "Look at the plus 2.")
        lesson.noteExchange(student: nil, tutor: "Try subtracting.")
        XCTAssertEqual(lesson.turns.map(\.role), [.student, .tutor, .tutor])
        XCTAssertEqual(lesson.recent.count, 3)
    }

    func testThePanelOpensAndClosesOnlyWhenAsked() {
        XCTAssertFalse(lesson.panelOpen)
        lesson.openPanel()
        XCTAssertTrue(lesson.panelOpen)
        lesson.closePanel()
        XCTAssertFalse(lesson.panelOpen)
        XCTAssertEqual(logRecords("lesson_panel_reopened").count, 1)
        XCTAssertEqual(logRecords("lesson_panel_closed").count, 1)
    }

    // MARK: - Logs and wording

    func testTheLogHoldsCountsAndLabelsButTheConceptOnlyWhereDebugKeepsWords() async {
        await startAndWaitForPractice()
        let requested = logRecords("lesson_requested").first
        XCTAssertEqual(requested?["concept_chars"] as? Int, "solving equations".count)
        XCTAssertEqual(requested?["course"] as? String, "bc-math-9-unit-3")
        let release = !TutorSession.logsWords
        if release { XCTAssertNil(requested?["concept"], "a Release build never logs the concept") }
        let everything = (try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? ""
        _ = log.exportURL()
        if release {
            for secret in ["solving equations", "Undo the last operation", "3x + 2 = 14", "sealed-ref-1"] {
                XCTAssertFalse(everything.contains(secret), "Release log leaks: \(secret)")
            }
        }
        XCTAssertFalse(everything.contains("sealed-ref-1"), "the sealed reference is never logged, even in Debug")
    }

    func testAClientWithoutTeachCallsStillCompilesAndSaysItDoesNotTeach() async {
        let old = FakeTutorClient()
        do {
            _ = try await old.teachExplain(TeachExplainRequest(sessionId: "s", course: "c", concept: "x"))
            XCTFail("a fake with no teach calls must throw")
        } catch let error as TutorError {
            guard case .notConfigured = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}
