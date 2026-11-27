import XCTest
@testable import PencilTutor

/// The hint callout grew from about 64 pt (words only) to about 120 pt (words, a gap, a 44 pt "Not a mistake" button, padding).
/// Placement must still keep all of it, button included, on screen and out of the strip the home-indicator swipe uses.
final class MarkCalloutTests: XCTestCase {
    private let size = CGSize(width: 260, height: 10 + 48 + 8 + 44 + 10)
    private let screen = CGRect(x: 0, y: 0, width: 1080, height: 810)
    private let keepOut: CGFloat = 24

    private var usable: CGRect { CGRect(x: 0, y: 0, width: screen.width, height: screen.height - keepOut) }

    func testTheTallCalloutStaysWhollyOnScreenWhateverRowTheCircleIsOn() {
        for y in stride(from: CGFloat(60), through: 780, by: 40) {
            for width in [CGFloat(200), 500, 1000] {
                let circle = CGRect(x: 40, y: y, width: width, height: 56)
                let origin = CalloutPlacement.origin(circle: circle, visible: usable, size: size)
                XCTAssertGreaterThanOrEqual(origin.x, 2, "circle at y \(y), width \(width)")
                XCTAssertGreaterThanOrEqual(origin.y, 2, "circle at y \(y), width \(width)")
                XCTAssertLessThanOrEqual(origin.x + size.width, usable.maxX - 2, "circle at y \(y), width \(width)")
                XCTAssertLessThanOrEqual(origin.y + size.height, usable.maxY - 2,
                                         "the button's bottom edge stays above the home-indicator strip (circle at y \(y), width \(width))")
            }
        }
    }

    func testAWideCircleNearTheBottomPutsTheCalloutAboveItSoTheButtonIsNotUnderTheSwipeZone() {
        let circle = CGRect(x: 300, y: 740, width: 760, height: 60)
        let origin = CalloutPlacement.origin(circle: circle, visible: usable, size: size)
        XCTAssertLessThan(origin.y + size.height, circle.minY, "above the circle")
        XCTAssertLessThanOrEqual(origin.y + size.height, screen.maxY - keepOut)
    }

    func testAMarkKeepsItsIdentityAndInkWhenThePageMoves() {
        let ink = InkIdentity(strokes: [InkStroke(id: 0, bounds: CGRect(x: 10, y: 10, width: 100, height: 20),
                                                  createdAt: Date(timeIntervalSinceReferenceDate: 5))])
        let mark = Mark(lineIndex: 2, box: CGRect(x: 0, y: 0, width: 200, height: 50), hint: "h", inkSignature: "10,10,100,20",
                        inkIdentity: ink, requestID: "r1", model: "m1")
        let moved = mark.moved(by: CGSize(width: 2700, height: 0))
        XCTAssertEqual(moved.id, mark.id, "the on-screen button and the voice bookkeeping follow the same mark")
        XCTAssertEqual(moved.inkIdentity, ink)
        XCTAssertEqual(moved.requestID, "r1")
        XCTAssertEqual(moved.model, "m1")
    }
}
