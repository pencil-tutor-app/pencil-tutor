import XCTest
@testable import PencilTutor

/// Line grouping is a hypothesis (plan amendment 7). These tests pin down what it does on the three hard cases:
/// stacked fractions, crossed-out work and a side calculation.
final class LineGrouperTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private func stroke(_ id: Int, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, at seconds: Double = 0) -> InkStroke {
        InkStroke(id: id, bounds: CGRect(x: x, y: y, width: w, height: h), createdAt: t0.addingTimeInterval(seconds))
    }

    /// Four strokes side by side on one row, ids starting at `firstID`.
    private func row(firstID: Int, y: CGFloat, h: CGFloat = 25) -> [InkStroke] {
        (0..<4).map { i in stroke(firstID + i, x: 20 + CGFloat(i) * 40, y: y, w: 30, h: h, at: Double(firstID + i)) }
    }

    func testThreePlainRowsBecomeThreeLinesNumberedTopToBottom() {
        let strokes = row(firstID: 0, y: 300) + row(firstID: 10, y: 100) + row(firstID: 20, y: 200)
        let lines = LineGrouper().group(strokes)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.map { $0.index }, [1, 2, 3])
        XCTAssertEqual(lines.map { $0.box.minY }, [100, 200, 300])
        XCTAssertEqual(lines.map { $0.strokeIDs.count }, [4, 4, 4])
        XCTAssertTrue(lines.allSatisfy { !$0.isSideCalculation })
    }

    func testLastStrokeTimeIsTheNewestStrokeInTheLine() {
        let lines = LineGrouper().group(row(firstID: 0, y: 100))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].lastStrokeAt, t0.addingTimeInterval(3))
    }

    func testEmptyPageHasNoLines() {
        XCTAssertTrue(LineGrouper().group([]).isEmpty)
    }

    func testStackedFractionOnItsOwnIsOneLineNotThree() {
        var strokes = row(firstID: 0, y: 50)                        // a line above
        strokes += [
            stroke(10, x: 100, y: 150, w: 30, h: 22),               // numerator
            stroke(11, x: 90, y: 180, w: 50, h: 4),                 // fraction bar
            stroke(12, x: 100, y: 192, w: 30, h: 22)                // denominator
        ]
        strokes += row(firstID: 20, y: 300)                         // a line below
        let lines = LineGrouper().group(strokes)
        XCTAssertEqual(lines.count, 3, "numerator, bar and denominator must be one line")
        XCTAssertEqual(lines.map { $0.strokeIDs.count }, [4, 3, 4])
        XCTAssertEqual(Set(lines[1].strokeIDs), [10, 11, 12])
    }

    func testFractionBesideTextStaysOneLine() {
        let strokes = [
            stroke(1, x: 20, y: 170, w: 20, h: 25),                 // x
            stroke(2, x: 50, y: 178, w: 24, h: 3),                  // = (top)
            stroke(3, x: 50, y: 186, w: 24, h: 3),                  // = (bottom)
            stroke(4, x: 100, y: 150, w: 30, h: 22),                // numerator
            stroke(5, x: 95, y: 180, w: 70, h: 4),                  // bar
            stroke(6, x: 100, y: 192, w: 30, h: 22),                // denominator
            stroke(7, x: 180, y: 178, w: 24, h: 3),                 // = (top)
            stroke(8, x: 215, y: 170, w: 15, h: 25)                 // 3
        ]
        let lines = LineGrouper().group(strokes)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].strokeIDs.count, 8)
        XCTAssertFalse(lines[0].isSideCalculation)
    }

    func testCrossedOutScribbleStaysInItsLineAndDoesNotSwallowTheNextLine() {
        var strokes = row(firstID: 0, y: 100)                       // line 1, y 100...125
        strokes += row(firstID: 10, y: 140)                         // line 2, y 140...165
        strokes.append(stroke(20, x: 15, y: 85, w: 170, h: 75))     // tall scribble centred on line 1
        let lines = LineGrouper().group(strokes)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].strokeIDs.contains(20), "the scribble belongs to line 1")
        XCTAssertEqual(lines[0].strokeIDs.count, 5)
        XCTAssertEqual(lines[1].strokeIDs.count, 4, "line 2 must not be pulled into line 1")
    }

    func testModestStrikeThroughJoinsItsLine() {
        var strokes = row(firstID: 0, y: 100)
        strokes.append(stroke(9, x: 20, y: 98, w: 100, h: 30))      // strike-through, only a little taller than the writing
        strokes += row(firstID: 20, y: 200)
        let lines = LineGrouper().group(strokes)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].strokeIDs.count, 5)
    }

    func testSideCalculationAtTheSameHeightBecomesItsOwnLine() {
        var strokes = (0..<4).map { stroke($0, x: 20 + CGFloat($0) * 90, y: 100, w: 30, h: 25) }   // x 20...300
        strokes += [stroke(10, x: 520, y: 105, w: 40, h: 20), stroke(11, x: 565, y: 105, w: 35, h: 20)]
        strokes += (0..<4).map { stroke(20 + $0, x: 20 + CGFloat($0) * 90, y: 200, w: 30, h: 25) }
        let lines = LineGrouper().group(strokes)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.map { $0.isSideCalculation }, [false, true, false])
        XCTAssertEqual(Set(lines[1].strokeIDs), [10, 11])
        XCTAssertEqual(lines[0].strokeIDs.count, 4)
    }

    func testSideCalculationBetweenLinesInTheRightMarginIsItsOwnSideLine() {
        var strokes = row(firstID: 0, y: 100)
        strokes += row(firstID: 10, y: 200)
        strokes += [stroke(20, x: 520, y: 150, w: 40, h: 20), stroke(21, x: 565, y: 150, w: 35, h: 20)]
        let lines = LineGrouper().group(strokes)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.map { $0.isSideCalculation }, [false, true, false])
        XCTAssertEqual(Set(lines[1].strokeIDs), [20, 21])
    }

    func testSameInkIgnoresIndexButNotNewStrokes() {
        let before = LineGrouper().group(row(firstID: 0, y: 100) + row(firstID: 10, y: 200))
        let withLineAbove = LineGrouper().group(row(firstID: 0, y: 100) + row(firstID: 10, y: 200) + row(firstID: 20, y: 20))
        XCTAssertEqual(withLineAbove.count, 3)
        XCTAssertTrue(before[1].isSameInk(as: withLineAbove[2]), "line 2 became line 3 but its ink is unchanged")
        XCTAssertFalse(before[0].isSameInk(as: withLineAbove[0]))
        let extended = LineGrouper().group(row(firstID: 0, y: 100) + [stroke(4, x: 180, y: 100, w: 30, h: 25, at: 50)])
        XCTAssertFalse(before[0].isSameInk(as: extended[0]), "an added stroke changes the line")
    }

    // MARK: - Superscripts, subscripts and stacked fractions on their own line (2026-11-15 handwriting replay)

    func testRaisedExponentStaysOnItsLine() {
        var strokes = row(firstID: 0, y: 100)                       // 100...125
        strokes.append(stroke(10, x: 172, y: 84, w: 10, h: 14))     // an exponent clear of the row: its bottom is 2 pt above it
        strokes += row(firstID: 20, y: 200)
        let lines = LineGrouper().group(strokes)
        XCTAssertEqual(lines.count, 2, "the exponent must not become a line of its own")
        XCTAssertEqual(lines[0].strokeIDs.count, 5)
        XCTAssertTrue(lines[0].strokeIDs.contains(10))
    }

    func testRaisedExponentFarFromTheRowStillBelongsToTheNearestLine() {
        var strokes = row(firstID: 0, y: 100)
        strokes.append(stroke(10, x: 172, y: 70, w: 10, h: 14))     // 16 pt above the row: raised high, still next to its base
        strokes += row(firstID: 20, y: 200)
        let lines = LineGrouper().group(strokes)
        XCTAssertEqual(lines.map { $0.strokeIDs.count }, [5, 4])
    }

    func testSubscriptBelowTheRowBelongsToItsLine() {
        var strokes = row(firstID: 0, y: 100)
        strokes.append(stroke(10, x: 92, y: 128, w: 9, h: 12))      // 3 pt under the row, beside the second letter
        strokes += row(firstID: 20, y: 200)
        let lines = LineGrouper().group(strokes)
        XCTAssertEqual(lines.map { $0.strokeIDs.count }, [5, 4])
    }

    func testALoneSmallMarkFarFromEveryLineStaysAlone() {
        var strokes = row(firstID: 0, y: 100)
        strokes.append(stroke(10, x: 60, y: 160, w: 6, h: 6))       // 35 pt below the row, not a subscript
        strokes += row(firstID: 20, y: 300)
        let lines = LineGrouper().group(strokes)
        XCTAssertEqual(lines.map { $0.strokeIDs.count }, [4, 1, 4])
    }

    /// Three letters, then a stacked fraction (numerator, bar, denominator) centred on `midY`, then one more letter.
    private func fractionLine(firstID: Int, midY: CGFloat) -> [InkStroke] {
        var out = (0..<3).map { i in stroke(firstID + i, x: 20 + CGFloat(i) * 35, y: midY - 12, w: 25, h: 25) }
        out.append(stroke(firstID + 3, x: 140, y: midY - 24, w: 30, h: 20))     // numerator
        out.append(stroke(firstID + 4, x: 130, y: midY - 1, w: 50, h: 3))       // bar
        out.append(stroke(firstID + 5, x: 140, y: midY + 4, w: 30, h: 20))      // denominator
        out.append(stroke(firstID + 6, x: 200, y: midY - 12, w: 25, h: 25))
        return out
    }

    func testTwoLinesEachWithAStackedFractionStayTwoLines() {
        // The fractions are 48 pt tall and the lines 56 pt apart, so the fractions nearly touch.
        let strokes = fractionLine(firstID: 0, midY: 100) + fractionLine(firstID: 10, midY: 156)
        let lines = LineGrouper().group(strokes)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map { $0.strokeIDs.count }, [7, 7])
        XCTAssertEqual(Set(lines[1].strokeIDs), Set(10..<17))
    }

    func testFractionLinesWithRaisedExponentsStayTwoLines() {
        var strokes = fractionLine(firstID: 0, midY: 100) + fractionLine(firstID: 10, midY: 170)
        strokes.append(stroke(30, x: 228, y: 84, w: 9, h: 12))      // an exponent on the last letter of line 1
        strokes.append(stroke(31, x: 228, y: 154, w: 9, h: 12))     // and one on line 2
        let lines = LineGrouper().group(strokes)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map { $0.strokeIDs.count }, [8, 8])
        XCTAssertTrue(lines[0].strokeIDs.contains(30))
        XCTAssertTrue(lines[1].strokeIDs.contains(31))
    }

    func testTheTopOfASevenIsNotAFractionBarThatPullsInTheLineAbove() {
        // A 7: a flat top and a stem that starts right at it. The row above is 10 pt over the top; a real fraction would have
        // writing about as close above its bar as below it.
        var strokes = row(firstID: 0, y: 100)                       // 100...125
        strokes.append(stroke(10, x: 62, y: 135, w: 24, h: 2))      // the top of the 7
        strokes.append(stroke(11, x: 66, y: 135, w: 14, h: 25))     // the stem, touching the top
        strokes.append(stroke(12, x: 20, y: 135, w: 30, h: 25))
        strokes.append(stroke(13, x: 100, y: 135, w: 30, h: 25))
        let lines = LineGrouper().group(strokes)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map { $0.strokeIDs.count }, [4, 4])
    }

    func testDescenderDippingIntoTheNextRowDoesNotMergeTheRows() {
        var strokes = row(firstID: 0, y: 100)                       // row 1: 100...125
        strokes[1] = stroke(1, x: 60, y: 100, w: 30, h: 35)         // a letter with a tail that reaches into row 2
        strokes += row(firstID: 10, y: 130)                         // row 2: 130...155, 5 pt below row 1's body
        let lines = LineGrouper().group(strokes)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map { $0.strokeIDs.count }, [4, 4])
    }

    func testSlantedRowsThatDriftStayApart() {
        // Each row climbs 12 pt over its length; the rows are 45 pt apart.
        func slanted(firstID: Int, y: CGFloat) -> [InkStroke] {
            (0..<6).map { i in stroke(firstID + i, x: 20 + CGFloat(i) * 40, y: y + CGFloat(i) * 2.4, w: 30, h: 25) }
        }
        let lines = LineGrouper().group(slanted(firstID: 0, y: 100) + slanted(firstID: 10, y: 145) + slanted(firstID: 20, y: 190))
        XCTAssertEqual(lines.map { $0.strokeIDs.count }, [6, 6, 6])
    }

    func testTheOrderStrokesArriveInDoesNotChangeTheLines() {
        var strokes = fractionLine(firstID: 0, midY: 100) + row(firstID: 10, y: 190)
        strokes.append(stroke(30, x: 228, y: 84, w: 9, h: 12))
        let expected = LineGrouper().group(strokes).map { $0.strokeIDs }
        for seed in 0..<5 {
            var generator = SeededGenerator(seed: UInt64(seed))
            XCTAssertEqual(LineGrouper().group(strokes.shuffled(using: &generator)).map { $0.strokeIDs }, expected)
        }
    }

    func testLetterHeightIgnoresDashesAndSpecks() {
        let letters = (0..<4).map { stroke($0, x: CGFloat($0) * 40, y: 100, w: 30, h: 25) }
        let dashes = (10..<30).map { stroke($0, x: CGFloat($0) * 10, y: 112, w: 24, h: 2) }
        let specks = (40..<50).map { stroke($0, x: CGFloat($0) * 10, y: 130, w: 3, h: 3) }
        XCTAssertEqual(LineGrouper.letterHeight(of: letters + dashes + specks), 25)
    }
}

/// Repeatable shuffling for the order test.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
