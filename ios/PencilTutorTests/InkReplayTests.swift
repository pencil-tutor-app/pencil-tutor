#if DEBUG
import PencilKit
import XCTest
@testable import PencilTutor

/// The debug-only ink replay (`--replay-ink`): reading a script and turning it into real PencilKit strokes.
@MainActor
final class InkReplayTests: XCTestCase {
    private let json = """
    {"version":1,"id":"demo","expected":{"outcome":"no_mistake"},
     "lines":[
       {"index":1,"text":"ignored","strokes":[{"points":[[10,20,1.0,0.2],[14,24,1.05,0.6],[18,28,1.1,0.4]]},
                                               {"points":[[30,20,1.3,0.3],[30,40,1.4,0.5]]}]},
       {"index":2,"strokes":[{"points":[[10,200,2.0,0.3],[50,203,2.2,0.7]]}]}]}
    """

    func testDecodeCountsLinesStrokesAndPoints() throws {
        let script = try InkReplay.decode(Data(json.utf8))
        XCTAssertEqual(script.id, "demo")
        XCTAssertEqual(script.lines.count, 2)
        XCTAssertEqual(script.strokeCount, 3)
        XCTAssertEqual(script.pointCount, 7)
    }

    func testStrokePointsLandOnThePageAtTheOriginAndKeepTheirTiming() throws {
        let script = try InkReplay.decode(Data(json.utf8))
        let origin = CGPoint(x: PageGeometry.homeReserve, y: PageGeometry.homeReserve)
        let stroke = InkReplay.makeStroke(script.lines[0].strokes[0], origin: origin, ink: PKInk(.pen, color: .black),
                                          width: 4, createdAt: Date(timeIntervalSinceReferenceDate: 100))
        XCTAssertEqual(stroke.path.count, 3)
        XCTAssertEqual(stroke.path.first?.location.x ?? 0, PageGeometry.homeReserve + 10, accuracy: 0.01)
        XCTAssertEqual(stroke.path.first?.location.y ?? 0, PageGeometry.homeReserve + 20, accuracy: 0.01)
        XCTAssertEqual(stroke.path.first?.timeOffset ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(stroke.path.last?.timeOffset ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertEqual(stroke.path.creationDate, Date(timeIntervalSinceReferenceDate: 100))
    }

    func testScriptedStrokesGroupIntoTheLinesTheyWereWrittenAs() throws {
        // Real strokes through the real grouper: two lines of ink far enough apart are two lines.
        let script = try InkReplay.decode(Data(json.utf8))
        let origin = CGPoint(x: PageGeometry.homeReserve, y: PageGeometry.homeReserve)
        let strokes = script.lines.flatMap(\.strokes).map {
            InkReplay.makeStroke($0, origin: origin, ink: PKInk(.pen, color: .black), width: 4, createdAt: Date())
        }
        let drawing = PKDrawing(strokes: strokes)
        let lines = LineGrouper().group(TutorSession.inkStrokes(from: drawing))
        XCTAssertEqual(lines.count, 2)
    }

    func testBadScriptsAreRejectedWithAReason() {
        XCTAssertThrowsError(try InkReplay.decode(Data("{\"id\":\"x\",\"lines\":[]}".utf8)))
        let onePoint = "{\"id\":\"x\",\"lines\":[{\"index\":1,\"strokes\":[{\"points\":[[1,2,3,0.5]]}]}]}"
        XCTAssertThrowsError(try InkReplay.decode(Data(onePoint.utf8)))
        XCTAssertThrowsError(try InkReplay.decode(Data("not json".utf8)))
    }
}
#endif
