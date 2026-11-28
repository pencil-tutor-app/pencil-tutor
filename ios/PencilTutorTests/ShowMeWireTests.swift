import XCTest
@testable import PencilTutor

/// "Show me how" on the wire: the solve request and reply, and the two consult fields that let the page reader answer `show_me`.
final class ShowMeWireTests: XCTestCase {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    func testASolveRequestIsSnakeCaseAndLeavesOutWhatABankProblemDoesNotHave() throws {
        let bank = try json(TeachSolveRequest(sessionId: "s", course: "linear-algebra", problemId: "la-02"))
        XCTAssertEqual(bank["action"] as? String, "solve")
        XCTAssertEqual(bank["session_id"] as? String, "s")
        XCTAssertEqual(bank["course"] as? String, "linear-algebra")
        XCTAssertEqual(bank["problem_id"] as? String, "la-02")
        XCTAssertNil(bank["problem_text"])
        XCTAssertNil(bank["problem_ref"])
        XCTAssertNil(bank["sessionId"], "snake_case on the wire")

        let practice = Problem.practice(courseSlug: "bc-math-9-unit-3", promptPlain: "Solve 3x + 2 = 14", ref: "sealed-ref")
        let sent = try json(TeachSolveRequest(sessionId: "s", course: "bc-math-9-unit-3", problemId: practice.id,
                                              problemText: practice.problemTextForServer, problemRef: practice.problemRef))
        XCTAssertEqual(sent["problem_id"] as? String, "own:bc-math-9-unit-3")
        XCTAssertEqual(sent["problem_text"] as? String, "Solve 3x + 2 = 14", "the server opens the reference against this statement")
        XCTAssertEqual(sent["problem_ref"] as? String, "sealed-ref")
    }

    func testASolveReplyDecodesTheStepsAndANotCheckedReplyHasNone() throws {
        let stored = #"{"solution":{"steps":["a","b","c","d","e","f","g"],"final_answer":"x = 1"},"reason":null,"model":"stored","latency_ms":4,"request_id":"r1"}"#
        let decoded = try JSONDecoder().decode(TeachSolveResponse.self, from: Data(stored.utf8))
        XCTAssertEqual(decoded.solution?.steps.count, 7, "however many steps the bank has")
        XCTAssertEqual(decoded.solution?.finalAnswer, "x = 1")
        XCTAssertNil(decoded.reason)
        XCTAssertEqual(decoded.model, "stored")
        XCTAssertEqual(decoded.requestId, "r1")

        let refused = #"{"solution":null,"reason":"not_checked","model":"gpt-6.1-sol","latency_ms":9}"#
        let none = try JSONDecoder().decode(TeachSolveResponse.self, from: Data(refused.utf8))
        XCTAssertNil(none.solution)
        XCTAssertEqual(none.reason, "not_checked")
    }

    func testAConsultRequestSendsShowMeOkOnlyWhenSet() throws {
        let plain = ConsultRequest(sessionId: "s", problemId: "u3-01", drawingRevision: 1, imagePngBase64: "B", question: "q", recent: [])
        XCTAssertNil(try json(plain)["show_me_ok"], "left out unless the app can show")
        var able = plain
        able.showMeOk = true
        XCTAssertEqual(try json(able)["show_me_ok"] as? Bool, true)
        XCTAssertNil(try json(able)["showMeOk"], "snake_case on the wire")
    }

    func testAConsultReplyDecodesShowMeAndAnOlderReplyHasNone() throws {
        let show = try JSONDecoder().decode(ConsultResponse.self, from: Data(#"{"answer_text":"","show_me":true,"model":"m","request_id":"r"}"#.utf8))
        XCTAssertEqual(show.showMe, true)
        XCTAssertEqual(show.answerText, "")
        let words = try JSONDecoder().decode(ConsultResponse.self, from: Data(#"{"answer_text":"Line two has a slip.","model":"m"}"#.utf8))
        XCTAssertNil(words.showMe)
        XCTAssertEqual(words.answerText, "Line two has a slip.")
    }

    func testTheScriptedTutorSolvesAnythingAndIsNotSureAboutOneStatement() async throws {
        let scripted = ScriptedTutorClient()
        let sure = try await scripted.teachSolve(TeachSolveRequest(sessionId: "s", course: "c", problemId: "u3-01"))
        XCTAssertEqual(sure.solution, ScriptedTutorClient.scriptedSolution)
        let unsure = try await scripted.teachSolve(TeachSolveRequest(sessionId: "s", course: "c", problemId: "own:c", problemText: "x + 1 = 2, No Confident Answer"))
        XCTAssertNil(unsure.solution)
        XCTAssertEqual(unsure.reason, "not_checked")
    }
}
