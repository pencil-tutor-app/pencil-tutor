import XCTest
@testable import PencilTutor

/// The teach requests and replies on the wire, the new fields on watch, ask, consult and live-session, and the scripted lesson.
final class TeachWireTests: XCTestCase {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private let practice = Problem.practice(courseSlug: "bc-math-9-unit-3", promptPlain: "Solve 3x + 2 = 14", ref: "sealed-ref")
    private let own = Problem.own(courseSlug: "bc-math-9-unit-3", text: "7x - 4 = 3x + 16")

    // MARK: - problem_ref, attempted, recent

    func testProblemRefIsOnTheWireInSnakeCaseForAPracticeProblemAndLeftOutOtherwise() throws {
        func watch(_ problem: Problem) -> WatchRequest {
            WatchRequest(sessionId: "s", problemId: problem.id, drawingRevision: 1, imagePngBase64: "A", imageWidth: 1, imageHeight: 1,
                         lines: [], history: [], clientTime: "t", problemText: problem.problemTextForServer, problemRef: problem.problemRef)
        }
        func ask(_ problem: Problem) -> AskRequest {
            AskRequest(sessionId: "s", problemId: problem.id, drawingRevision: 1, audioBase64: "A", imagePngBase64: "B",
                       problemText: problem.problemTextForServer, problemRef: problem.problemRef)
        }
        func consult(_ problem: Problem) -> ConsultRequest {
            ConsultRequest(sessionId: "s", problemId: problem.id, drawingRevision: 1, imagePngBase64: "B", question: "q", recent: [],
                           problemText: problem.problemTextForServer, problemRef: problem.problemRef)
        }
        func live(_ problem: Problem) -> LiveSessionRequest {
            LiveSessionRequest(sessionId: "s", problemId: problem.id, sdp: "v=0", problemText: problem.problemTextForServer, problemRef: problem.problemRef)
        }
        for (name, object) in [("watch", try json(watch(practice))), ("ask", try json(ask(practice))),
                               ("consult", try json(consult(practice))), ("live-session", try json(live(practice)))] {
            XCTAssertEqual(object["problem_ref"] as? String, "sealed-ref", "\(name) carries the sealed reference")
            XCTAssertEqual(object["problem_id"] as? String, "own:bc-math-9-unit-3")
            XCTAssertEqual(object["problem_text"] as? String, "Solve 3x + 2 = 14", "the server matches the reference to this text")
            XCTAssertNil(object["problemRef"], "\(name): snake_case on the wire")
        }
        for problem in [own, Problem(id: "u3-01", promptPlain: "Solve 2x + 3 = 11")] {
            for (name, object) in [("watch", try json(watch(problem))), ("ask", try json(ask(problem))),
                                   ("consult", try json(consult(problem))), ("live-session", try json(live(problem)))] {
                XCTAssertNil(object["problem_ref"], "\(name) leaves problem_ref out for a \(problem.kindLabel) problem")
                XCTAssertNil(object["attempted"])
            }
        }
    }

    func testAskCarriesAttemptedAndTheLastTurnsAndConsultCarriesAttempted() throws {
        let turns = [ConsultTurnWire(role: "student", text: "hi"), ConsultTurnWire(role: "tutor", text: "hello")]
        let ask = AskRequest(sessionId: "s", problemId: practice.id, drawingRevision: 1, audioBase64: "A", imagePngBase64: "B",
                             problemText: practice.problemTextForServer, problemRef: "sealed-ref", attempted: false, recent: turns)
        let askJSON = try json(ask)
        XCTAssertEqual(askJSON["attempted"] as? Bool, false, "false is sent, not left out: missing would read the same, but explicit is checked")
        let recent = try XCTUnwrap(askJSON["recent"] as? [[String: Any]])
        XCTAssertEqual(recent.map { $0["role"] as? String }, ["student", "tutor"])
        XCTAssertEqual(recent.map { $0["text"] as? String }, ["hi", "hello"])

        let consult = ConsultRequest(sessionId: "s", problemId: practice.id, drawingRevision: 1, imagePngBase64: "B", question: "q", recent: [],
                                     problemText: practice.problemTextForServer, problemRef: "sealed-ref", attempted: true)
        XCTAssertEqual(try json(consult)["attempted"] as? Bool, true)
    }

    func testAnOwnProblemAskLeavesRecentOutSoItsBodyIsUnchanged() throws {
        let ask = AskRequest(sessionId: "s", problemId: own.id, drawingRevision: 1, audioBase64: "A", imagePngBase64: "B",
                             problemText: own.problemTextForServer)
        XCTAssertNil(try json(ask)["recent"])
    }

    func testAPracticeProblemIsNeverEncodedWithItsReference() throws {
        // The reference lives only for the screen that holds the problem; a Problem that is saved or sent as JSON drops it.
        let object = try json(practice)
        XCTAssertNil(object["problem_ref"])
        XCTAssertNil(object["problemRef"])
        XCTAssertEqual(object["id"] as? String, "own:bc-math-9-unit-3")
    }

    // MARK: - The teach calls

    func testTheThreeTeachRequestsNameTheirActionAndUseSnakeCase() throws {
        let explain = try json(TeachExplainRequest(sessionId: "s", course: "calculus-1", concept: "integration by parts"))
        XCTAssertEqual(explain["action"] as? String, "explain")
        XCTAssertEqual(explain["session_id"] as? String, "s")
        XCTAssertEqual(explain["course"] as? String, "calculus-1")
        XCTAssertEqual(explain["concept"] as? String, "integration by parts")

        let followup = try json(TeachFollowupRequest(sessionId: "s", course: "c", concept: "x", lessonText: "lesson",
                                                     recent: [ConsultTurnWire(role: "student", text: "q")], question: "why?"))
        XCTAssertEqual(followup["action"] as? String, "followup")
        XCTAssertEqual(followup["lesson_text"] as? String, "lesson")
        XCTAssertEqual(followup["question"] as? String, "why?")
        XCTAssertNil(followup["audio_base64"])
        XCTAssertNil(followup["problem_ref"])
        XCTAssertNil(followup["attempted"])

        let spoken = try json(TeachFollowupRequest(sessionId: "s", course: "c", concept: "x", lessonText: "lesson", recent: [],
                                                   audioBase64: "AAAA", problemText: "Solve 3x + 2 = 14", problemRef: "ref", attempted: false))
        XCTAssertEqual(spoken["audio_base64"] as? String, "AAAA")
        XCTAssertNil(spoken["question"])
        XCTAssertEqual(spoken["problem_ref"] as? String, "ref")
        XCTAssertEqual(spoken["problem_text"] as? String, "Solve 3x + 2 = 14")
        XCTAssertEqual(spoken["attempted"] as? Bool, false)

        let example = TeachExample(promptPlain: "Solve 2x + 1 = 9", steps: ["2x = 8"], finalAnswer: "x = 4")
        let practiceRequest = try json(TeachPracticeRequest(sessionId: "s", course: "c", concept: "x", lessonText: "lesson", example: example))
        XCTAssertEqual(Set(practiceRequest.keys), ["action", "session_id", "course", "concept", "lesson_text", "example"],
                       "exactly the keys the server's practice schema reads, no nested lesson")
        XCTAssertEqual(practiceRequest["action"] as? String, "practice")
        XCTAssertEqual(practiceRequest["lesson_text"] as? String, "lesson")
        let sent = try XCTUnwrap(practiceRequest["example"] as? [String: Any])
        XCTAssertEqual(sent["prompt_plain"] as? String, "Solve 2x + 1 = 9")
        XCTAssertEqual(sent["final_answer"] as? String, "x = 4")
    }

    func testTheTeachRepliesDecodeFromTheServersSnakeCase() throws {
        let explain = try JSONDecoder().decode(TeachExplainResponse.self, from: Data("""
        {"is_math":true,"fits_course":true,"message":null,"title":"T","steps":["a","b"],
         "example":{"prompt_plain":"p","steps":["s"],"final_answer":"x = 4"},"spoken":"hi","request_id":"r","model":"m","latency_ms":9}
        """.utf8))
        XCTAssertTrue(explain.isMath)
        XCTAssertEqual(explain.lesson?.title, "T")
        XCTAssertEqual(explain.lesson?.example.finalAnswer, "x = 4")
        XCTAssertEqual(explain.lesson?.spoken, "hi")
        XCTAssertEqual(explain.latencyMs, 9)
        XCTAssertNotNil(Lesson(explain))

        let refused = try JSONDecoder().decode(TeachExplainResponse.self, from: Data(
            #"{"is_math":true,"fits_course":false,"message":"That belongs to another course; pick it there.","title":null,"steps":null,"example":null,"spoken":null}"#.utf8))
        XCTAssertEqual(refused.fitsCourse, false)
        XCTAssertEqual(refused.message, "That belongs to another course; pick it there.")
        XCTAssertNil(Lesson(refused), "a refusal has no lesson")

        let bare = try JSONDecoder().decode(TeachExplainResponse.self, from: Data(#"{"is_math":false}"#.utf8))
        XCTAssertFalse(bare.isMath)
        XCTAssertNil(bare.fitsCourse)
        XCTAssertNil(Lesson(bare), "a reply with no lesson is not a lesson")

        let practice = try JSONDecoder().decode(TeachPracticeResponse.self, from: Data(
            #"{"problem":{"id":"own:c","prompt_plain":"Solve 3x + 2 = 14"},"problem_ref":"ref","example_checked":true,"request_id":"r"}"#.utf8))
        XCTAssertEqual(practice.problem?.promptPlain, "Solve 3x + 2 = 14")
        XCTAssertEqual(practice.problemRef, "ref")
        XCTAssertEqual(practice.exampleChecked, true)

        let unchecked = try JSONDecoder().decode(TeachPracticeResponse.self, from: Data(
            #"{"problem":null,"reason":"not_checked","example_checked":false}"#.utf8))
        XCTAssertNil(unchecked.problem)
        XCTAssertEqual(unchecked.reason, "not_checked")

        let followup = try JSONDecoder().decode(TeachFollowupResponse.self, from: Data(#"{"transcript":"why","answer_text":"Because."}"#.utf8))
        XCTAssertEqual(followup.answerText, "Because.")
    }

    /// The literal body the server's scripted mode sends (`SCRIPTED_LESSON` in server/lib/teach.ts, spread flat next to the flags), plus the
    /// fields every reply carries.
    func testTheServersLiteralScriptedExplainReplyDecodesIntoALesson() throws {
        let reply = try JSONDecoder().decode(TeachExplainResponse.self, from: Data("""
        {"is_math":true,"fits_course":true,"message":null,
         "title":"Solving a two-step equation",
         "steps":["Undo the adding or subtracting first.","Then undo the multiplying by dividing both sides by the same number."],
         "example":{"prompt_plain":"3x + 2 = 14","steps":["3x = 12","x = 4"],"final_answer":"x = 4"},
         "spoken":"A two-step equation needs two undoing moves, one at a time.",
         "model":"scripted","latency_ms":3,"request_id":"req_1"}
        """.utf8))
        let lesson = try XCTUnwrap(Lesson(reply), "title, steps and example present: a lesson")
        XCTAssertEqual(lesson.title, "Solving a two-step equation")
        XCTAssertEqual(lesson.steps.count, 2)
        XCTAssertEqual(lesson.example.promptPlain, "3x + 2 = 14")
        XCTAssertEqual(lesson.example.steps, ["3x = 12", "x = 4"])
        XCTAssertEqual(lesson.example.finalAnswer, "x = 4")
        XCTAssertEqual(lesson.spoken, "A two-step equation needs two undoing moves, one at a time.")
        XCTAssertEqual(reply.model, "scripted")
        XCTAssertEqual(reply.requestId, "req_1")
    }

    /// The server's refusal bodies: the lesson fields are present and null (NO_LESSON in server/lib/teach.ts), with the server's words.
    func testTheServersRefusedExplainRepliesDecodeWithNoLesson() throws {
        let notMath = try JSONDecoder().decode(TeachExplainResponse.self, from: Data("""
        {"is_math":false,"fits_course":false,"message":"I can teach maths topics only.",
         "title":null,"steps":null,"example":null,"spoken":null,"model":"gpt-6.1-sol","latency_ms":2400,"request_id":"req_2"}
        """.utf8))
        XCTAssertFalse(notMath.isMath)
        XCTAssertEqual(notMath.message, "I can teach maths topics only.")
        XCTAssertNil(notMath.lesson)
        XCTAssertNil(Lesson(notMath))

        let otherCourse = try JSONDecoder().decode(TeachExplainResponse.self, from: Data("""
        {"is_math":true,"fits_course":false,"message":"That belongs to another course; pick it there.",
         "title":null,"steps":null,"example":null,"spoken":null,"model":"gpt-6.1-sol","latency_ms":2100}
        """.utf8))
        XCTAssertTrue(otherCourse.isMath)
        XCTAssertEqual(otherCourse.fitsCourse, false)
        XCTAssertNil(otherCourse.lesson)
    }

    func testAnExplainReplyMissingAnyLessonFieldIsNotALesson() throws {
        let noExample = try JSONDecoder().decode(TeachExplainResponse.self, from: Data(
            #"{"is_math":true,"fits_course":true,"message":null,"title":"T","steps":["a"],"example":null,"spoken":"s"}"#.utf8))
        XCTAssertNil(noExample.lesson, "no example: the lesson is incomplete, so it is a failure and never a half panel")
        let reencoded = try JSONDecoder().decode(TeachExplainResponse.self, from: JSONEncoder().encode(try XCTUnwrap(JSONDecoder().decode(
            TeachExplainResponse.self, from: Data(#"{"is_math":true,"fits_course":true,"message":null,"title":"T","steps":["a"],"example":{"prompt_plain":"p","steps":[],"final_answer":"x"},"spoken":null}"#.utf8)))))
        XCTAssertEqual(reencoded.lesson?.title, "T", "encoding stays flat and round trips")
    }

    // MARK: - Errors

    func testTheServersTeachLabelsBecomeTheirOwnErrors() {
        func error(_ status: Int, _ error: String?, _ reason: String? = nil) -> TutorError {
            HTTPTutorClient.error(status: status, body: ServerErrorBody(error: error, reason: reason, allowance: nil))
        }
        XCTAssertEqual(error(422, "practice_expired", "reference_expired").logDetail, TutorError.practiceExpired.logDetail)
        XCTAssertEqual(error(422, "invalid_request", "practice_expired").logDetail, TutorError.practiceExpired.logDetail, "either field may carry it")
        XCTAssertEqual(error(502, "teach_too_long").studentMessage, "That came out too long, try again.")
        XCTAssertEqual(error(502, "teach_unusable", "lesson_incomplete").logDetail, TutorError.teachUnusable.logDetail)
        XCTAssertEqual(error(503, "teach_unavailable", "TEACH_SEAL_KEY is not set").logDetail, TutorError.teachUnavailable.logDetail)
        XCTAssertEqual(error(503, "model_unavailable").logDetail, TutorError.serverUnavailable(status: 503, reason: "model_unavailable").logDetail,
                       "other 503s are unchanged")
    }

    // MARK: - Concept and lesson text

    func testTheConceptIsCleanedAndCappedAt200TheWayTheServerCounts() {
        XCTAssertNil(LearnConcept.cleaned("  \n "))
        XCTAssertEqual(LearnConcept.cleaned("  integration\nby parts "), "integration by parts")
        XCTAssertEqual(LearnConcept.cleaned(String(repeating: "x", count: 300))?.utf16.count, 200)
        XCTAssertEqual(LearnConcept.capped(String(repeating: "x", count: 199) + "\u{1F600}"), String(repeating: "x", count: 199))
    }

    func testTheLessonTextFitsTheServersLimitAndLeavesTheExampleOutUntilChecked() throws {
        let response = TeachExplainResponse(
            isMath: true, fitsCourse: true, message: nil,
            lesson: TeachLesson(title: "Title", steps: ["one", "two"], example: TeachExample(promptPlain: "P", steps: ["s1", "s2"], finalAnswer: "x = 4"))
        )
        let lesson = try XCTUnwrap(Lesson(response))
        XCTAssertEqual(lesson.text(includeExample: false), "Title\n1. one\n2. two")
        XCTAssertTrue(lesson.text(includeExample: true).hasSuffix("Example: P\ns1\ns2\nAnswer: x = 4"))
        XCTAssertEqual(lesson.exampleLines, 4)

        let long = TeachExplainResponse(isMath: true, fitsCourse: true, message: nil, lesson: TeachLesson(
            title: "T", steps: (1...50).map { _ in String(repeating: "w", count: 100) }, example: TeachExample(promptPlain: "P", steps: [], finalAnswer: "x")))
        XCTAssertLessThanOrEqual(try XCTUnwrap(Lesson(long)).text(includeExample: false).count, LessonText.maxCharacters)
    }

    // MARK: - Scripted tutor and the shared type setting

    func testTheScriptedTutorReturnsAFixedLessonAndACheckedPracticeProblem() async throws {
        let scripted = ScriptedTutorClient()
        let lesson = try await scripted.teachExplain(TeachExplainRequest(sessionId: "s", course: "bc-math-9-unit-3", concept: "anything"))
        XCTAssertEqual(lesson.lesson?.title, "Undoing an operation")
        XCTAssertEqual(lesson.lesson?.steps.count, 4)
        let refused = try await scripted.teachExplain(TeachExplainRequest(sessionId: "s", course: "c", concept: "Baking bread"))
        XCTAssertFalse(refused.isMath)
        let practice = try await scripted.teachPractice(TeachPracticeRequest(sessionId: "s", course: "bc-math-9-unit-3", concept: "x", lessonText: "l", example: lesson.lesson?.example))
        XCTAssertEqual(practice.problem?.promptPlain, ScriptedTutorClient.scriptedPracticePrompt)
        XCTAssertEqual(practice.problemRef, ScriptedTutorClient.scriptedPracticeRef)
        XCTAssertEqual(practice.exampleChecked, true)
        let answer = try await scripted.teachFollowup(TeachFollowupRequest(sessionId: "s", course: "c", concept: "x", lessonText: "l", recent: [], question: "q"))
        XCTAssertFalse(answer.answerText.isEmpty)
    }

    func testMathParagraphLosesNoCharacterOfALine() {
        func rebuilt(_ text: String) -> String {
            MathParagraph.pieces(of: [.text(text)]).compactMap { piece -> String? in
                if case .word(_, let nodes) = piece { return MathMarkup.plainText(nodes) }
                return nil
            }.joined(separator: " ")
        }
        let sentence = "Undo the last operation first, then the one before it."
        XCTAssertEqual(rebuilt(sentence), sentence, "plain words come back as written")
        let maths = rebuilt("Then x^2 = 9 gives x = ±3 and √(2x + 1) = 5 means 2x + 1 = 25.")
        for piece in ["Then", "= 9", "gives", "±3", "√", "= 5", "means", "= 25."] {
            XCTAssertTrue(maths.contains(piece), "\"\(piece)\" is drawn: \(maths)")
        }
        let withFraction = MathParagraph.pieces(of: [.text("Add"), .fraction(numerator: "1", denominator: "2"), .text("to both sides.")])
        XCTAssertEqual(withFraction.count, 5, "Add, the fraction, then to, both, sides.")
    }
}
