import XCTest
@testable import PencilTutor

final class ProblemBankTests: XCTestCase {
    func testDecodesTextAndFractionParts() throws {
        let json = """
        [{
          "id": "u3-06",
          "prompt_latex": "a over 3 plus a over 4 = 14",
          "prompt_plain": "a/3 + a/4 = 14",
          "prompt_parts": [
            { "frac": { "num": "a", "den": "3" } },
            { "text": " + " },
            { "frac": { "num": "a", "den": "4" } },
            { "text": " = 14" }
          ],
          "worked_solution": ["secret"],
          "final_answer": "a = 24"
        }]
        """
        let problems = try ProblemBank.decode(Data(json.utf8))
        XCTAssertEqual(problems.count, 1)
        XCTAssertEqual(problems[0].id, "u3-06")
        XCTAssertEqual(problems[0].promptParts, [
            .fraction(numerator: "a", denominator: "3"),
            .text(" + "),
            .fraction(numerator: "a", denominator: "4"),
            .text(" = 14")
        ])
    }

    func testMissingPartsFallBackToPlainText() throws {
        let json = #"[{"id":"x","prompt_plain":"x + 1 = 2"}]"#
        let problems = try ProblemBank.decode(Data(json.utf8))
        XCTAssertEqual(problems[0].promptParts, [.text("x + 1 = 2")])
    }

    func testAPartWithNeitherTextNorFractionIsRejected() {
        let json = #"[{"id":"x","prompt_plain":"x","prompt_parts":[{"bogus":1}]}]"#
        XCTAssertThrowsError(try ProblemBank.decode(Data(json.utf8)))
    }

    /// Reads the real committed bank from the repo (the test runs on the simulator, which shares the host disk).
    func testTheRealSharedProblemBankDecodes() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PencilTutorTests
            .deletingLastPathComponent()   // ios
            .deletingLastPathComponent()   // repo root
        let url = repoRoot.appendingPathComponent("shared/problems.json")
        let data = try Data(contentsOf: url)
        let problems = try ProblemBank.decode(data)
        XCTAssertGreaterThanOrEqual(problems.count, 10)
        XCTAssertEqual(Set(problems.map { $0.id }).count, problems.count, "ids must be unique")
        XCTAssertTrue(problems.contains { $0.id == ScriptedTutorClient.plantedProblemID }, "the planted problem must exist")
        XCTAssertTrue(problems.contains { $0.id == "u3-01" }, "the clean problem used by the UI test must exist")
        XCTAssertTrue(problems.allSatisfy { !$0.promptParts.isEmpty && !$0.promptPlain.isEmpty })
        XCTAssertTrue(problems.contains { problem in
            problem.promptParts.contains { if case .fraction = $0 { return true } else { return false } }
        }, "the bank should include stacked fractions")
    }

    func testTheBundledBankHasNoAnswersInIt() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "problems", withExtension: "json"),
                                "the build step must copy problems.json into the app")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("worked_solution"))
        XCTAssertFalse(text.contains("final_answer"))
        let problems = try ProblemBank.loadBundled()
        XCTAssertGreaterThanOrEqual(problems.count, 10)
    }
}
