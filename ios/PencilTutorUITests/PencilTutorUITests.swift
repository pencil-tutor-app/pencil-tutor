import XCTest

/// Runs the app with the in-process scripted tutor (`--scripted-client`) and a finger standing in for the Pencil
/// (`--any-input`). These prove the wiring: strokes become lines, the look happens after the idle time, and the
/// red circle and hint appear on the right line, or nothing appears. They do not prove tutoring judgment.
final class PencilTutorUITests: XCTestCase {
    private let plantedProblem = "u3-04"
    private let cleanProblem = "u3-01"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--scripted-client", "--any-input"]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func open(problem id: String, in app: XCUIApplication) {
        let row = element(app, "problem-\(id)")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "problem \(id) should be in the list")
        row.tap()
        XCTAssertTrue(element(app, "drawingCanvas").waitForExistence(timeout: 10), "the drawing canvas should appear")
    }

    /// Draws one "line" of work: four short slanted strokes side by side at the same height.
    private func drawLine(_ row: Int, on canvas: XCUIElement) {
        for stroke in 0..<4 {
            let x = 0.08 + 0.17 * Double(stroke)
            let y = 0.10 + 0.22 * Double(row)
            let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
            let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: x + 0.12, dy: y + 0.03))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    private func waitForStatus(_ app: XCUIApplication, containing text: String, timeout: TimeInterval) -> Bool {
        let status = element(app, "testStatus")
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: status)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func screenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(
            uniformTypeIdentifier: "public.png",
            name: name,
            payload: app.screenshot().pngRepresentation,
            userInfo: nil
        )
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPlantedMistakeGetsACircleAndAHintOnLineTwo() throws {
        let app = launchApp()
        open(problem: plantedProblem, in: app)
        screenshot(app, named: "01-planted-problem-shown")

        let canvas = element(app, "drawingCanvas")
        for row in 0..<3 { drawLine(row, on: canvas) }

        XCTAssertTrue(waitForStatus(app, containing: "strokes=12", timeout: 10),
                      "twelve strokes should register; status was: \(element(app, "testStatus").label)")
        XCTAssertTrue(waitForStatus(app, containing: "lines=3", timeout: 5),
                      "three lines should be found; status was: \(element(app, "testStatus").label)")
        screenshot(app, named: "02-planted-ink-drawn")

        let circle = element(app, "interruptEllipse")
        XCTAssertTrue(circle.waitForExistence(timeout: 20),
                      "the scripted tutor should circle a line; status was: \(element(app, "testStatus").label)")
        let hint = element(app, "hintText")
        XCTAssertTrue(hint.waitForExistence(timeout: 5))
        XCTAssertTrue(circle.label.contains("line 2"), "the circle should be on line 2, was: \(circle.label)")
        XCTAssertEqual(hint.label, "Check the signs here")
        screenshot(app, named: "03-planted-red-circle-and-hint-on-line-2")
    }

    func testCleanProblemIsLeftAlone() throws {
        let app = launchApp()
        open(problem: cleanProblem, in: app)
        screenshot(app, named: "04-clean-problem-shown")

        let canvas = element(app, "drawingCanvas")
        for row in 0..<2 { drawLine(row, on: canvas) }
        XCTAssertTrue(waitForStatus(app, containing: "strokes=8", timeout: 10),
                      "eight strokes should register; status was: \(element(app, "testStatus").label)")

        // Past the 2.5 s idle time the tutor looks, the scripted answer is "wait", and nothing is marked.
        XCTAssertTrue(waitForStatus(app, containing: "last=wait", timeout: 20),
                      "the tutor should have looked and decided to wait; status was: \(element(app, "testStatus").label)")
        XCTAssertFalse(element(app, "interruptEllipse").exists, "nothing should be circled on the clean problem")
        XCTAssertFalse(element(app, "hintText").exists, "no hint should appear on the clean problem")
        screenshot(app, named: "05-clean-looked-and-left-alone")
    }
}
