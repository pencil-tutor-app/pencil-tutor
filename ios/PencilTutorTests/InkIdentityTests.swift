import PencilKit
import XCTest
@testable import PencilTutor

/// "Not a mistake" is remembered against the ink, not against a line number or a signature of rounded boxes. These tests pin down
/// what survives what: a page re-anchor, lines renumbering when a line is written above, and erasing an earlier stroke (which
/// renumbers `InkStroke.id`); and what must end it: adding, erasing or redrawing a stroke of the line.
final class InkIdentityTests: XCTestCase {
    private let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A pen stroke whose left end is at (x, y), started `seconds` after the epoch (each stroke gets its own start time, like a pen-down).
    private func penStroke(x: CGFloat, y: CGFloat, at seconds: TimeInterval) -> PKStroke {
        var points: [PKStrokePoint] = []
        for step in 0..<12 {
            points.append(PKStrokePoint(location: CGPoint(x: x + CGFloat(step) * 20, y: y + CGFloat(step % 3) * 6),
                                        timeOffset: Double(step) * 0.01, size: CGSize(width: 4, height: 4),
                                        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
        }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: points, creationDate: epoch.addingTimeInterval(seconds)))
    }

    private func strokes(_ drawing: PKDrawing) -> [InkStroke] { TutorSession.inkStrokes(from: drawing) }

    private func identity(ofLineAt row: Int, in drawing: PKDrawing) throws -> InkIdentity {
        let all = strokes(drawing)
        let lines = LineGrouper().group(all)
        return InkIdentity(line: try XCTUnwrap(lines.first { $0.index == row }), in: all)
    }

    // MARK: - What survives

    /// The reviewer's trap: re-anchoring moves every stroke, so a signature of rounded boxes changes. A stroke's start time and
    /// size do not. This also proves PencilKit keeps the start time through `transformed`, which the whole design relies on.
    func testIdentitySurvivesAPageReanchorThatMovesEveryStroke() throws {
        let drawing = PKDrawing(strokes: [penStroke(x: 3100, y: 3100, at: 1), penStroke(x: 3100, y: 3200, at: 2), penStroke(x: 3340, y: 3200, at: 3)])
        let before = try identity(ofLineAt: 2, in: drawing)
        XCTAssertEqual(before.strokes.count, 2)

        let moved = drawing.transformed(using: CGAffineTransform(translationX: 2700, y: 0))
        let after = try identity(ofLineAt: 2, in: moved)

        XCTAssertNotEqual(strokes(drawing)[1].bounds, strokes(moved)[1].bounds, "the ink really moved")
        XCTAssertEqual(strokes(drawing).map(\.id), strokes(moved).map(\.id), "ids are positions, and a re-anchor keeps the order")
        XCTAssertTrue(before.isSameInk(as: after), "same strokes, so the same ink")
        let signatureBefore = Mark.inkSignature(in: CGRect(x: 3000, y: 3150, width: 600, height: 100), strokes: strokes(drawing))
        let signatureAfter = Mark.inkSignature(in: CGRect(x: 3000, y: 3150, width: 600, height: 100), strokes: strokes(moved))
        XCTAssertNotEqual(signatureBefore, signatureAfter, "the old rounded-box signature does change (this is why it cannot key a dispute)")
    }

    func testIdentitySurvivesAnEarlierStrokeBeingErasedWhichRenumbersTheIds() throws {
        let drawing = PKDrawing(strokes: [penStroke(x: 3100, y: 3100, at: 1), penStroke(x: 3100, y: 3200, at: 2)])
        let before = try identity(ofLineAt: 2, in: drawing)
        XCTAssertEqual(LineGrouper().group(strokes(drawing)).last?.strokeIDs, [1])

        let erasedFirst = PKDrawing(strokes: Array(drawing.strokes.dropFirst()))
        XCTAssertEqual(LineGrouper().group(strokes(erasedFirst)).last?.strokeIDs, [0], "the same stroke is now id 0: ids are not identity")
        let after = try identity(ofLineAt: 1, in: erasedFirst)
        XCTAssertTrue(before.isSameInk(as: after))
    }

    func testIdentitySurvivesALineBeingWrittenAboveItSoTheLineNumberChanges() throws {
        let original = PKDrawing(strokes: [penStroke(x: 3100, y: 3200, at: 1), penStroke(x: 3100, y: 3300, at: 2)])
        let disputed = try identity(ofLineAt: 2, in: original)

        let withNewLineAbove = PKDrawing(strokes: original.strokes + [penStroke(x: 3100, y: 3100, at: 3)])
        let lines = LineGrouper().group(strokes(withNewLineAbove))
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(try identity(ofLineAt: 3, in: withNewLineAbove).isSameInk(as: disputed), "the disputed line is line 3 now")
        XCTAssertFalse(try identity(ofLineAt: 2, in: withNewLineAbove).isSameInk(as: disputed))
    }

    // MARK: - What ends it

    func testAddingErasingOrRedrawingAStrokeMakesItDifferentInk() throws {
        let drawing = PKDrawing(strokes: [penStroke(x: 3100, y: 3100, at: 1), penStroke(x: 3340, y: 3100, at: 2)])
        let before = try identity(ofLineAt: 1, in: drawing)

        let added = PKDrawing(strokes: drawing.strokes + [penStroke(x: 3580, y: 3100, at: 3)])
        XCTAssertFalse(try identity(ofLineAt: 1, in: added).isSameInk(as: before), "a stroke added to the line")
        XCTAssertTrue(before.isStillOnPage(strokes(added)), "everything that was disputed is still there")

        let erased = PKDrawing(strokes: [drawing.strokes[0]])
        XCTAssertFalse(try identity(ofLineAt: 1, in: erased).isSameInk(as: before), "a stroke erased")
        XCTAssertFalse(before.isStillOnPage(strokes(erased)))

        let redrawn = PKDrawing(strokes: [drawing.strokes[0], penStroke(x: 3340, y: 3100, at: 9)])
        XCTAssertFalse(try identity(ofLineAt: 1, in: redrawn).isSameInk(as: before),
                       "a rewritten stroke in the very same place has a new start time")
        XCTAssertFalse(before.isStillOnPage(strokes(redrawn)))
    }

    func testAScaledStrokeIsAChangedStroke() throws {
        let drawing = PKDrawing(strokes: [penStroke(x: 3100, y: 3100, at: 1)])
        let before = InkIdentity(strokes: strokes(drawing))
        let scaled = drawing.transformed(using: CGAffineTransform(scaleX: 1.5, y: 1.5))
        XCTAssertFalse(before.isSameInk(as: InkIdentity(strokes: strokes(scaled))))
    }

    // MARK: - The book

    func testTheBookCoversExactlyTheDisputedInkAndDropsDisputesWhoseInkWasEdited() throws {
        let drawing = PKDrawing(strokes: [penStroke(x: 3100, y: 3100, at: 1), penStroke(x: 3100, y: 3200, at: 2)])
        let lineOne = try identity(ofLineAt: 1, in: drawing)
        let lineTwo = try identity(ofLineAt: 2, in: drawing)

        var book = DisputeBook()
        XCTAssertNil(book.covering(lineTwo))
        book.add(Dispute(lineIndex: 2, requestID: "r1", ink: lineTwo))
        XCTAssertEqual(book.covering(lineTwo)?.requestID, "r1")
        XCTAssertNil(book.covering(lineOne), "another line is not covered")
        XCTAssertNil(book.covering(.none), "nothing is covered by empty ink")

        book.add(Dispute(lineIndex: 2, requestID: "r2", ink: lineTwo))
        XCTAssertEqual(book.count, 1, "disputing the same ink again replaces the first")

        XCTAssertTrue(book.dropEdited(page: strokes(drawing)).isEmpty, "untouched ink keeps its dispute")
        let withoutLineTwo = PKDrawing(strokes: [drawing.strokes[0]])
        XCTAssertEqual(book.dropEdited(page: strokes(withoutLineTwo)).map(\.lineIndex), [2])
        XCTAssertEqual(book.count, 0)
    }

    func testTheBookKeepsAtMostItsLimit() {
        var book = DisputeBook()
        for index in 0..<(DisputeBook.limit + 5) {
            let stroke = InkStroke(id: 0, bounds: CGRect(x: 0, y: 0, width: 10, height: 10), createdAt: epoch.addingTimeInterval(Double(index) * 5))
            book.add(Dispute(lineIndex: index, requestID: nil, ink: InkIdentity(strokes: [stroke])))
        }
        XCTAssertEqual(book.count, DisputeBook.limit)
        XCTAssertEqual(book.disputes.first?.lineIndex, 5, "the oldest are forgotten first")
    }
}
