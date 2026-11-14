import XCTest
@testable import PencilTutor

final class StudentCodeTests: XCTestCase {
    func testAlphabetHasThirtySymbolsAndNoLookAlikes() {
        XCTAssertEqual(StudentCode.alphabet.count, 30)
        XCTAssertEqual(Set(StudentCode.alphabet).count, 30, "no repeats")
        for banned in "ILOU01" {
            XCTAssertFalse(StudentCode.alphabet.contains(banned), "\(banned) must not be in the alphabet")
        }
    }

    func testNormalizeTrimsUppercasesAndDropsSpacesAndDashes() {
        XCTAssertEqual(StudentCode.normalize("  abcd-efgh \n"), "ABCDEFGH")
        XCTAssertEqual(StudentCode.normalize("ab cd\u{2013}ef\u{2014}gh"), "ABCDEFGH")
        XCTAssertEqual(StudentCode.normalize(""), "")
    }

    func testValidNeedsExactlyEightCharactersFromTheAlphabet() {
        XCTAssertTrue(StudentCode.isValid("ABCDEFGH"))
        XCTAssertTrue(StudentCode.isValid("23456789"))
        XCTAssertFalse(StudentCode.isValid("ABCDEFG"), "seven")
        XCTAssertFalse(StudentCode.isValid("ABCDEFGHJ"), "nine")
        for banned in ["ABCDEFG0", "ABCDEFGO", "ABCDEFG1", "ABCDEFGI", "ABCDEFGL", "ABCDEFGU"] {
            XCTAssertFalse(StudentCode.isValid(banned), "\(banned) has a look-alike character")
        }
        XCTAssertFalse(StudentCode.isValid("abcdefgh"), "lowercase must be normalized first")
    }

    func testProblemLabelsSayWhyACodeIsNotAcceptedYet() {
        XCTAssertEqual(StudentCode.problem(with: ""), "empty")
        XCTAssertEqual(StudentCode.problem(with: "ABC"), "too_short")
        XCTAssertEqual(StudentCode.problem(with: "ABCDEFGHJK"), "too_long")
        XCTAssertEqual(StudentCode.problem(with: "ABCDEFG0"), "characters_not_in_alphabet")
        XCTAssertNil(StudentCode.problem(with: "ABCDEFGH"))
    }

    func testDisplayAndMaskNeverShowMoreThanTheFirstFour() {
        XCTAssertEqual(StudentCode.display("ABCDEFGH"), "ABCD-EFGH")
        XCTAssertEqual(StudentCode.display("ABC"), "ABC")
        XCTAssertEqual(StudentCode.display("ABCDE"), "ABCD-E")
        XCTAssertEqual(StudentCode.masked("ABCDEFGH"), "ABCD-••••")
        XCTAssertFalse(StudentCode.masked("ABCDEFGH").contains("EFGH"))
    }

    func testShortHashIsSixHexCharactersOfSHA256() {
        // printf ABCDEFGH | shasum -a 256  ->  9ac219...
        XCTAssertEqual(StudentCode.shortHash("ABCDEFGH"), "9ac219")
        XCTAssertEqual(StudentCode.shortHash("ABCDEFGH").count, 6)
        XCTAssertNotEqual(StudentCode.shortHash("ABCDEFGH"), StudentCode.shortHash("ABCDEFGJ"))
        XCTAssertFalse(StudentCode.shortHash("ABCDEFGH").contains("ABCD"))
    }

    func testInMemoryStoreAndHolder() throws {
        let store = InMemoryStudentCodeStore()
        XCTAssertNil(store.load())
        try store.save("ABCDEFGH")
        XCTAssertEqual(store.load(), "ABCDEFGH")
        store.clear()
        XCTAssertNil(store.load())

        let holder = StudentCodeHolder()
        XCTAssertNil(holder.current)
        holder.current = "ABCDEFGH"
        XCTAssertEqual(holder.current, "ABCDEFGH")
        holder.current = nil
        XCTAssertNil(holder.current)
    }
}
