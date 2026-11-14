import SwiftUI
import XCTest
@testable import PencilTutor

/// The notation problems are written in becomes exponents, roots, matrices and Σ bounds. These tests pin down the reader
/// (`MathMarkup`), the word cutting the card wraps on, and the style of the text it hands to SwiftUI.
final class MathMarkupTests: XCTestCase {
    private func t(_ s: String) -> MathNode { .text(s) }

    // MARK: - Exponents and indices

    func testAParenthesisedExponentBecomesASuperscript() {
        XCTAssertEqual(MathMarkup.parse("x^(1/3)"), [t("x"), .sup([t("1/3")])])
        XCTAssertEqual(MathMarkup.parse("e^(−3x)"), [t("e"), .sup([t("−3x")])])
    }

    func testABracedExponentAndASingleTokenExponent() {
        XCTAssertEqual(MathMarkup.parse("2^{n}"), [t("2"), .sup([t("n")])])
        XCTAssertEqual(MathMarkup.parse("5^x."), [t("5"), .sup([t("x")]), t(".")])
        XCTAssertEqual(MathMarkup.parse("10^100 is big"), [t("10"), .sup([t("100")]), t(" is big")])
        XCTAssertEqual(MathMarkup.parse("a^−2"), [t("a"), .sup([t("−2")])])
    }

    func testOnlyOneTokenFollowsABareCaret() {
        // `x^2y` is x squared times y, not x to the power 2y.
        XCTAssertEqual(MathMarkup.parse("x^2y"), [t("x"), .sup([t("2")]), t("y")])
    }

    func testNestedExponents() {
        XCTAssertEqual(MathMarkup.parse("2^(x^2)"), [t("2"), .sup([t("x"), .sup([t("2")])])])
    }

    func testSubscripts() {
        XCTAssertEqual(MathMarkup.parse("a_{n+1} = 2a_n"), [t("a"), .sub([t("n+1")]), t(" = 2a"), .sub([t("n")])])
    }

    func testUnicodeScriptsAreReadTheSameWay() {
        XCTAssertEqual(MathMarkup.parse("x² + y³"), [t("x"), .sup([t("2")]), t(" + y"), .sup([t("3")])])
        XCTAssertEqual(MathMarkup.parse("A⁻¹"), [t("A"), .sup([t("−1")])])
        XCTAssertEqual(MathMarkup.parse("(AB)ᵀ"), [t("(AB)"), .sup([t("T")])])
        XCTAssertEqual(MathMarkup.parse("t₂₀"), [t("t"), .sub([t("20")])])
    }

    func testAMarkWithNothingUsableAfterItStaysText() {
        XCTAssertEqual(MathMarkup.parse("a ^ b"), [t("a ^ b")])
        XCTAssertEqual(MathMarkup.parse("x^(1/3"), [t("x^(1/3")])
        XCTAssertEqual(MathMarkup.parse("end^"), [t("end^")])
        XCTAssertEqual(MathMarkup.parse("snake_ case"), [t("snake_ case")])
    }

    // MARK: - Roots

    func testRoots() {
        XCTAssertEqual(MathMarkup.parse("√(2x + 1)"), [.root(index: nil, [t("2x + 1")])])
        XCTAssertEqual(MathMarkup.parse("√x"), [.root(index: nil, [t("x")])])
        XCTAssertEqual(MathMarkup.parse("√36, √20"), [.root(index: nil, [t("36")]), t(", "), .root(index: nil, [t("20")])])
        XCTAssertEqual(MathMarkup.parse("∛125"), [.root(index: 3, [t("125")])])
        XCTAssertEqual(MathMarkup.parse("∛(8/27)"), [.root(index: 3, [t("8/27")])])
    }

    func testARootOnlyCoversItsNumberOrGroup() {
        XCTAssertEqual(MathMarkup.parse("√3/2"), [.root(index: nil, [t("3")]), t("/2")])
        XCTAssertEqual(MathMarkup.parse("2√3"), [t("2"), .root(index: nil, [t("3")])])
    }

    func testARootWithExponentsInside() {
        XCTAssertEqual(MathMarkup.parse("√(9x² + 1)"), [.root(index: nil, [t("9x"), .sup([t("2")]), t(" + 1")])])
    }

    func testARootSignWithNothingAfterItStaysText() {
        XCTAssertEqual(MathMarkup.parse("√ is the root sign"), [t("√ is the root sign")])
    }

    // MARK: - Matrices

    func testAMatrixIsRowsOfCells() {
        XCTAssertEqual(MathMarkup.parse("A = [1 2; 3 4]"), [t("A = "), .matrix([[[t("1")], [t("2")]], [[t("3")], [t("4")]]])])
    }

    func testMatrixCellsKeepTheirSigns() {
        XCTAssertEqual(MathMarkup.parse("[2 −1; 0 3]"), [.matrix([[[t("2")], [t("−1")]], [[t("0")], [t("3")]]])])
    }

    func testAMatrixOfSeveralSizes() {
        guard case .matrix(let rows) = MathMarkup.parse("[1 2 1 3; 2 4 3 7]")[0] else { return XCTFail("not a matrix") }
        XCTAssertEqual(rows.map { $0.count }, [4, 4])
        guard case .matrix(let three) = MathMarkup.parse("[2 1; 0 −1; 3 4]")[0] else { return XCTFail("not a matrix") }
        XCTAssertEqual(three.map { $0.count }, [2, 2, 2])
    }

    func testBracketsWithoutASemicolonAreNotMatrices() {
        XCTAssertEqual(MathMarkup.parse("on [0, 2]"), [t("on [0, 2]")])
        XCTAssertEqual(MathMarkup.parse("[A | I]"), [t("[A | I]")])
    }

    // MARK: - Sums

    func testSigmaKeepsItsBoundsAboveAndBelow() {
        XCTAssertEqual(MathMarkup.parse("Evaluate Σ_{k=1}^{20} (3k − 2)."),
                       [t("Evaluate "), .limits(symbol: "Σ", lower: [t("k=1")], upper: [t("20")]), t(" (3k − 2).")])
        XCTAssertEqual(MathMarkup.parse("Σ_{k=0}^{7} 3·2^k"),
                       [.limits(symbol: "Σ", lower: [t("k=0")], upper: [t("7")]), t(" 3·2"), .sup([t("k")])])
    }

    // MARK: - Plain text and words

    func testPlainTextWritesTheMarkupBackOut() {
        XCTAssertEqual(MathMarkup.plainText(MathMarkup.parse("x^(1/3) + y²")), "x^(1/3) + y^2")
        XCTAssertEqual(MathMarkup.plainText(MathMarkup.parse("[1 2; 3 4]")), "[1 2; 3 4]")
        XCTAssertEqual(MathMarkup.plainText(MathMarkup.parse("√x")), "√(x)")
    }

    func testAnExponentStaysWithItsWord() {
        let words = MathMarkup.words(MathMarkup.parse("Evaluate 27^(2/3) now"))
        XCTAssertEqual(words, [[t("Evaluate")], [t("27"), .sup([t("2/3")])], [t("now")]])
    }

    func testAMatrixIsItsOwnWordBetweenOtherWords() {
        let words = MathMarkup.words(MathMarkup.parse("The matrix is P = [0.8 0.3; 0.2 0.7] (columns: from city). Find it."))
        XCTAssertEqual(words.first, [t("The")])
        XCTAssertEqual(words.last, [t("it.")])
        let matrixWords = words.filter { word in word.contains { node in if case .matrix = node { return true } else { return false } } }
        XCTAssertEqual(matrixWords.count, 1)
        XCTAssertEqual(matrixWords[0].count, 1, "the matrix stands alone between P = and (columns:")
        XCTAssertTrue(words.contains([t("(columns:")]))
    }

    func testAnIntervalBracketStaysInOnePiece() {
        let words = MathMarkup.words(MathMarkup.parse("Find f on [0, 2] now"))
        XCTAssertTrue(words.contains([t("[0,\u{00A0}2]")]), "\(words)")
    }

    func testAnOverlongBracketIsLeftToWrap() {
        let long = "[" + String(repeating: "word ", count: 12) + "end]"
        XCTAssertGreaterThan(MathMarkup.words(MathMarkup.parse(long)).count, 5)
    }

    func testARootNextToANumberIsOneWord() {
        let words = MathMarkup.words(MathMarkup.parse("Find 4√x − 6/x³"))
        XCTAssertEqual(words[1], [t("4"), .root(index: nil, [t("x")])])
    }

    // MARK: - Style of the text

    func testScriptsAreSmallerAndRaisedOrLowered() {
        let up = MathMarkup.scriptStyle(level: 1, raised: true)
        let down = MathMarkup.scriptStyle(level: 1, raised: false)
        XCTAssertEqual(up.scale, 0.7, accuracy: 0.001)
        XCTAssertGreaterThan(up.shift, 0)
        XCTAssertLessThan(down.shift, 0)
        XCTAssertEqual(MathMarkup.scriptStyle(level: 2, raised: true).scale, 0.49, accuracy: 0.001)
    }

    func testAnExponentIsRaisedAboveTheBaseline() {
        let text = MathRunView.attributed(MathMarkup.parse("x^(1/3)"), size: 20)
        let offsets = text.runs.map { (String(text[$0.range].characters), $0.baselineOffset) }
        XCTAssertEqual(offsets.map { $0.0 }, ["x", "1/3"])
        XCTAssertNil(offsets[0].1, "the base sits on the baseline")
        XCTAssertEqual(try XCTUnwrap(offsets[1].1), 8, accuracy: 0.01, "40% of 20 pt")
    }

    func testAnExponentOfAnExponentIsRaisedAgainFromTheFirst() {
        let text = MathRunView.attributed(MathMarkup.parse("2^(x^2)"), size: 20)
        let raised = text.runs.compactMap { $0.baselineOffset }
        XCTAssertEqual(raised.count, 2)
        XCTAssertEqual(raised[1], raised[0] + 14 * 0.4, accuracy: 0.01, "the inner exponent rises by 40% of the outer's 14 pt")
    }

    func testASubscriptDropsBelowTheBaseline() {
        let text = MathRunView.attributed(MathMarkup.parse("a_n"), size: 20)
        let drops = text.runs.compactMap { $0.baselineOffset }
        XCTAssertEqual(drops.count, 1)
        XCTAssertLessThan(drops[0], 0)
    }

    // MARK: - Every prompt in every course

    /// The characters that carry meaning, with the markup stripped, are the same before and after reading. So reading never
    /// drops or invents anything.
    private func bare(_ s: String) -> String {
        let scripts: [Character: Character] = [
            "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9", "⁺": "+", "⁻": "−",
            "ⁿ": "n", "ˣ": "x", "ᵀ": "T", "ᶜ": "c", "₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4", "₅": "5", "₆": "6", "₇": "7",
            "₈": "8", "₉": "9", "ₙ": "n"
        ]
        let markup: Set<Character> = ["^", "_", "(", ")", "{", "}", "[", "]", ";", " ", "\u{00A0}", "-", "−"]
        return String(s.compactMap { c -> Character? in
            let mapped = scripts[c] ?? c
            return markup.contains(mapped) ? nil : mapped
        })
    }

    private func leftoverMarkup(_ nodes: [MathNode], into found: inout [String]) {
        for node in nodes {
            switch node {
            case .text(let text):
                if text.contains("^") { found.append("^ in \(text)") }
                if text.contains("_{") { found.append("_{ in \(text)") }
                if text.contains(where: { "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻ⁿ₀₁₂₃₄₅₆₇₈₉ₙ".contains($0) }) { found.append("unicode script in \(text)") }
                if text.contains(";"), text.contains("[") { found.append("matrix as text in \(text)") }
            case .sup(let inner), .sub(let inner), .root(_, let inner):
                leftoverMarkup(inner, into: &found)
            case .limits(_, let lower, let upper):
                leftoverMarkup(lower, into: &found)
                leftoverMarkup(upper, into: &found)
            case .matrix(let rows):
                rows.forEach { $0.forEach { leftoverMarkup($0, into: &found) } }
            }
        }
    }

    func testEveryPromptInEveryCourseReadsCleanlyAndLosesNothing() throws {
        let shared = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared")
        struct Entry: Decodable { let file: String }
        struct Manifest: Decodable { let courses: [Entry] }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: shared.appendingPathComponent("courses/index.json")))
        var checked = 0
        var problemsWithLeftovers: [String] = []
        for entry in manifest.courses {
            for problem in try ProblemBank.decode(Data(contentsOf: shared.appendingPathComponent(entry.file))) {
                for part in problem.promptParts {
                    let strings: [String]
                    switch part {
                    case .text(let text): strings = [text]
                    case .fraction(let numerator, let denominator): strings = [numerator, denominator]
                    }
                    for string in strings {
                        let nodes = MathMarkup.parse(string)
                        XCTAssertEqual(bare(MathMarkup.plainText(nodes)), bare(string), "\(problem.id): \(string)")
                        var found: [String] = []
                        leftoverMarkup(nodes, into: &found)
                        if !found.isEmpty { problemsWithLeftovers.append("\(problem.id): \(found)") }
                        checked += 1
                    }
                }
                XCTAssertFalse(MathMarkup.words(MathMarkup.parse(problem.promptPlain)).isEmpty, problem.id)
            }
        }
        XCTAssertGreaterThan(checked, 1000)
        XCTAssertEqual(problemsWithLeftovers, [], "raw markup left on the card")
    }
}
