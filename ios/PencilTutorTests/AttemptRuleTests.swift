import XCTest
@testable import PencilTutor

/// "Has the student really started the practice problem?" Geometry only. Blank, partial, erased and crossed-out work must all say
/// "not yet"; real work says "yes" only after it has stayed unchanged across one look.
final class AttemptRuleTests: XCTestCase {
    private let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var nextID = 0

    private func stroke(_ rect: CGRect, at seconds: TimeInterval = 1) -> InkStroke {
        defer { nextID += 1 }
        return InkStroke(id: nextID, bounds: rect, createdAt: epoch.addingTimeInterval(seconds))
    }

    /// A line of `count` letter-sized strokes (24 wide, 30 tall, 30 apart) starting at (`x`, `y`).
    private func writing(count: Int, x: CGFloat = 100, y: CGFloat, at seconds: TimeInterval = 1) -> [InkStroke] {
        (0..<count).map { stroke(CGRect(x: x + CGFloat($0) * 30, y: y, width: 24, height: 30), at: seconds + Double($0)) }
    }

    /// A flat stroke across a line, through the middle of the letters.
    private func strikeThrough(y: CGFloat, from x0: CGFloat, to x1: CGFloat) -> InkStroke {
        stroke(CGRect(x: x0, y: y + 13, width: x1 - x0, height: 4), at: 40)
    }

    // MARK: - What counts as a line of work

    func testABlankPageHasNoWork() {
        XCTAssertTrue(AttemptRule.workLines([]).isEmpty)
        var tracker = AttemptTracker()
        XCTAssertFalse(tracker.look([]))
        XCTAssertFalse(tracker.attempted([]))
    }

    func testAFewMarksArePartialNotWork() {
        let one = writing(count: 1, y: 100)
        let three = writing(count: 3, y: 100)
        XCTAssertTrue(AttemptRule.workLines(one).isEmpty, "a single stroke is not a line of work")
        XCTAssertTrue(AttemptRule.workLines(three).isEmpty, "three strokes (\"2x\" and a start) are still partial")
        var tracker = AttemptTracker()
        _ = tracker.look(three)
        XCTAssertFalse(tracker.attempted(three), "partial work stays \"not yet\" however long it sits there")
    }

    func testADoodleThatIsTooSmallIsNotWork() {
        let tiny = (0..<6).map { stroke(CGRect(x: 100 + CGFloat($0) * 3, y: 100, width: 2, height: 30)) }
        XCTAssertTrue(AttemptRule.workLines(tiny).isEmpty, "six strokes squeezed into 20 points are a smudge, not a line")
    }

    func testAFinishedLineIsWork() {
        let line = writing(count: 5, y: 100)
        XCTAssertEqual(AttemptRule.workLines(line).count, 1)
    }

    func testAScribbleFarToTheRightIsASideCalculationNotWork() {
        let main = writing(count: 2, y: 100)
        let side = writing(count: 5, x: 700, y: 100)
        XCTAssertTrue(AttemptRule.workLines(main + side).isEmpty, "the main line is partial and the side calculation is not counted")
    }

    // MARK: - Crossed out

    func testALineWithAStrikeThroughIsNotWork() {
        let line = writing(count: 5, y: 100)
        XCTAssertEqual(AttemptRule.workLines(line).count, 1)
        let struck = line + [strikeThrough(y: 100, from: 95, to: 260)]
        XCTAssertTrue(AttemptRule.workLines(struck).isEmpty, "crossed out work is not an attempt")
    }

    func testADiagonalSlashAndAScribbleBothCrossALineOut() {
        let line = writing(count: 5, y: 100)
        let slash = stroke(CGRect(x: 95, y: 95, width: 170, height: 40), at: 40)
        XCTAssertTrue(AttemptRule.workLines(line + [slash]).isEmpty, "a slash across the line crosses it out")
        let scribble = stroke(CGRect(x: 95, y: 40, width: 170, height: 150), at: 40)
        XCTAssertTrue(AttemptRule.workLines(line + [scribble]).isEmpty, "a tall scribble across the line crosses it out")
    }

    func testOneBigScribbleCrossesOutEveryLineItRunsThrough() {
        let page = writing(count: 5, y: 100) + writing(count: 5, y: 170) + writing(count: 5, y: 240)
        let scribble = stroke(CGRect(x: 90, y: 90, width: 180, height: 190), at: 40)
        XCTAssertTrue(AttemptRule.workLines(page + [scribble]).isEmpty, "the scribble joins the middle line but crosses out all three")
    }

    func testAnUnderlineAndAFractionBarAreNotStrikes() {
        let line = writing(count: 5, y: 100)
        let underline = stroke(CGRect(x: 95, y: 138, width: 170, height: 3), at: 40)
        XCTAssertEqual(AttemptRule.workLines(line + [underline]).count, 1, "an underline runs beside the work, not through it")

        // Numerator over a bar over a denominator, then an equals sign and a result: the bar is wide but crosses nothing.
        let numerator = [stroke(CGRect(x: 110, y: 60, width: 24, height: 30)), stroke(CGRect(x: 150, y: 60, width: 24, height: 30))]
        let bar = stroke(CGRect(x: 100, y: 96, width: 100, height: 3))
        let denominator = [stroke(CGRect(x: 110, y: 104, width: 24, height: 30)), stroke(CGRect(x: 150, y: 104, width: 24, height: 30))]
        let result = writing(count: 3, x: 230, y: 80)
        XCTAssertEqual(AttemptRule.workLines(numerator + [bar] + denominator + result).count, 1)
    }

    // MARK: - Unchanged across one look

    func testALineCountsOnlyAfterItStayedUnchangedAcrossALook() {
        let line = writing(count: 5, y: 100)
        var tracker = AttemptTracker()
        XCTAssertFalse(tracker.attempted(line), "nothing has been looked at yet")
        XCTAssertFalse(tracker.look(line), "the first look sees the line for the first time")
        XCTAssertTrue(tracker.attempted(line), "a question after that look sees it unchanged")
        XCTAssertTrue(tracker.look(line), "and the next look agrees")
    }

    func testEditingTheLineAfterALookResetsIt() {
        let line = writing(count: 5, y: 100)
        var tracker = AttemptTracker()
        _ = tracker.look(line)
        let longer = line + writing(count: 1, x: 100 + 5 * 30, y: 100, at: 60)
        XCTAssertFalse(tracker.attempted(longer), "a stroke added since the look makes it a different line")
        XCTAssertFalse(tracker.look(longer))
        XCTAssertTrue(tracker.attempted(longer), "unchanged across the next look: attempted again")
    }

    func testErasedWorkIsNotAnAttempt() {
        let line = writing(count: 5, y: 100)
        var tracker = AttemptTracker()
        _ = tracker.look(line)
        XCTAssertTrue(tracker.attempted(line))
        XCTAssertFalse(tracker.attempted([]), "the page was erased after the look")
        XCTAssertFalse(tracker.attempted(Array(line.prefix(2))), "most of the line was erased")
        tracker.reset()
        XCTAssertFalse(tracker.attempted(line), "Erase page forgets what the looks saw")
    }

    func testStrikingTheLineOutAfterALookTakesTheAttemptBack() {
        let line = writing(count: 5, y: 100)
        var tracker = AttemptTracker()
        _ = tracker.look(line)
        XCTAssertTrue(tracker.attempted(line))
        XCTAssertFalse(tracker.attempted(line + [strikeThrough(y: 100, from: 95, to: 260)]))
    }

    func testAPageReanchorHoldsTheAttemptBackUntilTheNextLook() {
        // A re-anchor moves every stroke, and `isSameInk` allows a point of drift, so a real move looks like a different line:
        // "not yet" until the next look sees it settled. Slower, never wrong in the dangerous direction.
        let line = writing(count: 5, y: 100)
        var tracker = AttemptTracker()
        _ = tracker.look(line)
        let nudged = line.map { InkStroke(id: $0.id, bounds: $0.bounds.offsetBy(dx: 0, dy: 0.4), createdAt: $0.createdAt) }
        XCTAssertTrue(tracker.attempted(nudged), "under a point of drift is the same line")
        let moved = line.map { InkStroke(id: $0.id, bounds: $0.bounds.offsetBy(dx: 0, dy: 300), createdAt: $0.createdAt) }
        XCTAssertFalse(tracker.attempted(moved), "300 points away is a different place until a look has seen it")
        XCTAssertFalse(tracker.look(moved))
        XCTAssertTrue(tracker.attempted(moved))
    }
}
