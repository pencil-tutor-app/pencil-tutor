import XCTest
@testable import PencilTutor

/// The student's own problem: the id, the typed statement, and where `problem_text` goes on the wire.
final class OwnProblemTests: XCTestCase {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    func testAnOwnProblemRoundTripsThroughJSONAndKeepsItsCourseAndText() throws {
        let own = Problem.own(courseSlug: "bc-math-9-unit-3", text: "7x - 4 = 3x + 16")
        XCTAssertEqual(own.id, "own:bc-math-9-unit-3")
        XCTAssertTrue(own.isOwn)
        XCTAssertEqual(own.ownCourseSlug, "bc-math-9-unit-3")
        XCTAssertEqual(own.promptPlain, "7x - 4 = 3x + 16")
        XCTAssertEqual(own.promptParts, [.text("7x - 4 = 3x + 16")], "the card shows the typed text like a bank prompt")

        let decoded = try JSONDecoder().decode(Problem.self, from: JSONEncoder().encode(own))
        XCTAssertEqual(decoded, own)
        XCTAssertTrue(decoded.isOwn)
        XCTAssertEqual(decoded.ownCourseSlug, "bc-math-9-unit-3")
    }

    func testABankProblemIsNotOwn() {
        let bank = Problem(id: "u3-01", promptPlain: "Solve 2x + 3 = 11")
        XCTAssertFalse(bank.isOwn)
        XCTAssertNil(bank.ownCourseSlug)
        XCTAssertNil(bank.problemTextForServer)
        XCTAssertEqual(Problem.own(courseSlug: "c", text: "x").problemTextForServer, "x")
    }

    func testProblemTextIsOnTheWireForOwnProblemsOnlyAndInSnakeCase() throws {
        let own = Problem.own(courseSlug: "bc-math-9-unit-3", text: "7x - 4 = 3x + 16")
        let bank = Problem(id: "u3-01", promptPlain: "Solve 2x + 3 = 11")

        func watch(_ problem: Problem) -> WatchRequest {
            WatchRequest(sessionId: "s", problemId: problem.id, drawingRevision: 1, imagePngBase64: "A", imageWidth: 1, imageHeight: 1,
                         lines: [], history: [], clientTime: "t", problemText: problem.problemTextForServer)
        }
        func ask(_ problem: Problem) -> AskRequest {
            AskRequest(sessionId: "s", problemId: problem.id, drawingRevision: 1, audioBase64: "A", imagePngBase64: "B",
                       problemText: problem.problemTextForServer)
        }
        func consult(_ problem: Problem) -> ConsultRequest {
            ConsultRequest(sessionId: "s", problemId: problem.id, drawingRevision: 1, imagePngBase64: "B", question: "q", recent: [],
                           problemText: problem.problemTextForServer)
        }
        func live(_ problem: Problem) -> LiveSessionRequest {
            LiveSessionRequest(sessionId: "s", problemId: problem.id, sdp: "v=0", problemText: problem.problemTextForServer)
        }

        for (name, object) in [("watch", try json(watch(own))), ("ask", try json(ask(own))),
                               ("consult", try json(consult(own))), ("live-session", try json(live(own)))] {
            XCTAssertEqual(object["problem_text"] as? String, "7x - 4 = 3x + 16", "\(name) carries the typed statement")
            XCTAssertEqual(object["problem_id"] as? String, "own:bc-math-9-unit-3")
            XCTAssertNil(object["problemText"], "\(name): snake_case on the wire")
        }
        for (name, object) in [("watch", try json(watch(bank))), ("ask", try json(ask(bank))),
                               ("consult", try json(consult(bank))), ("live-session", try json(live(bank)))] {
            XCTAssertNil(object["problem_text"], "\(name) leaves problem_text out for a bank problem")
        }
    }

    /// No new scripted branch: the scripted tutor already waits on every problem id except the planted one.
    func testTheScriptedTutorAlwaysWaitsOnAnOwnProblem() async throws {
        let request = WatchRequest(sessionId: "s", problemId: "own:bc-math-9-unit-3", drawingRevision: 3, imagePngBase64: "", imageWidth: 1, imageHeight: 1,
                                   lines: [1, 2, 3].map { LineWire(index: $0, box: BoxWire(x: 0, y: 0, w: 1, h: 1), lastStrokeAt: "t") },
                                   history: [], clientTime: "t", problemText: "7x - 4 = 3x + 16")
        let reply = try await ScriptedTutorClient().watch(request)
        XCTAssertEqual(reply.action, "wait")
    }

    func testTypedTextIsCleanedAndCappedTheWayTheServerCounts() {
        XCTAssertNil(OwnProblemText.cleaned(""))
        XCTAssertNil(OwnProblemText.cleaned("   \n  "))
        XCTAssertEqual(OwnProblemText.cleaned("  2x + 3 = 11  "), "2x + 3 = 11")
        XCTAssertEqual(OwnProblemText.cleaned("Solve:\n2x + 3 = 11"), "Solve: 2x + 3 = 11", "a line break becomes a space")

        let long = String(repeating: "x", count: 600)
        XCTAssertEqual(OwnProblemText.cleaned(long)?.utf16.count, 500)
        XCTAssertEqual(OwnProblemText.capped(String(repeating: "x", count: 500)).utf16.count, 500, "exactly 500 is kept whole")
        // 499 letters then a 2-unit emoji: the emoji would be the 501st unit, so it is dropped whole, not cut in half.
        let nearTheEnd = String(repeating: "x", count: 499) + "\u{1F600}"
        XCTAssertEqual(OwnProblemText.capped(nearTheEnd), String(repeating: "x", count: 499))
    }
}
