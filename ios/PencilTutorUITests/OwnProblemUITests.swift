import XCTest

/// "My own problem" (first row of a course's list, a one-field sheet, Start opens the page) and the hint callout's "Not a mistake"
/// button. Run on CI (ios.yml) against the scripted tutor; they attach screenshots as receipts. Not run on the laptop.
final class OwnProblemUITests: XCTestCase {
    private let course = "bc-math-9-unit-3"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--scripted-client", "--any-input", "--silent", "-lastCourseSlug", ""]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: name,
                                       payload: XCUIScreen.main.screenshot().pngRepresentation, userInfo: nil)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openCourse(_ app: XCUIApplication) {
        let row = element(app, "course-\(course)")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the course is on the picker")
        row.tap()
    }

    private func waitForStatus(_ app: XCUIApplication, containing text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element(app, "testStatus"))
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Four short strokes side by side at row `row` (same shape the other UI tests draw).
    private func drawLine(_ row: Int, on canvas: XCUIElement) {
        for stroke in 0..<4 {
            let x = 0.12 + 0.17 * Double(stroke)
            let y = 0.22 + 0.20 * Double(row)
            let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
            let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: x + 0.12, dy: y + 0.03))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    /// One short stroke between two points given in screen points (window coordinates).
    private func drawStroke(in app: XCUIApplication, from: CGPoint, to: CGPoint) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: from.x, dy: from.y))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: to.x, dy: to.y)))
    }

    // MARK: - My own problem

    func testOwnProblemRowIsFirstTheSheetNeedsTextAndStartOpensThePage() throws {
        let app = launchApp()
        openCourse(app)

        let ownRow = element(app, "ownProblemRow")
        XCTAssertTrue(ownRow.waitForExistence(timeout: 10), "the first row of the course list is My own problem")
        let firstBankRow = element(app, "problem-u3-01")
        XCTAssertTrue(firstBankRow.waitForExistence(timeout: 10))
        XCTAssertLessThan(ownRow.frame.minY, firstBankRow.frame.minY, "it sits above the bank problems")
        XCTAssertGreaterThanOrEqual(ownRow.frame.height, 43.5, "a tap target of at least 44 pt")
        screenshot("40-own-problem-row-first")

        // Cancel closes the sheet and leaves the list as it was.
        ownRow.tap()
        let field = element(app, "ownProblemField")
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the sheet has one text field")
        XCTAssertTrue(element(app, "ownProblemCancelButton").exists)
        screenshot("41-own-problem-sheet-empty")
        element(app, "ownProblemCancelButton").tap()
        XCTAssertTrue(ownRow.waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "ownProblemField").exists, "Cancel closed the sheet")
        XCTAssertFalse(element(app, "drawingCanvas").exists, "and opened nothing")

        // Start stays off until something is typed.
        ownRow.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let start = element(app, "ownProblemStartButton")
        XCTAssertTrue(start.exists)
        XCTAssertFalse(start.isEnabled, "Start is disabled while the field is empty")
        field.tap()
        field.typeText("7x - 4 = 3x + 16")
        XCTAssertTrue(start.isEnabled, "Start turns on once there is a problem")
        screenshot("42-own-problem-sheet-typed")

        start.tap()
        XCTAssertTrue(element(app, "drawingCanvas").waitForExistence(timeout: 15), "Start opens the page")
        let prompt = element(app, "problemPrompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        XCTAssertTrue(prompt.label.contains("7x"), "the card shows what was typed, was: \(prompt.label)")
        screenshot("43-own-problem-page")
    }

    // MARK: - Not a mistake

    /// The scripted tutor circles line 2 of u3-04. The callout has a 44 pt "Not a mistake" button; ink next to it and on the hint's
    /// own words still draws (only the button takes a touch); tapping it takes the circle off.
    func testNotAMistakeButtonDismissesTheCircleAndInkAroundItStillDraws() throws {
        let app = launchApp()
        openCourse(app)
        let row = element(app, "problem-u3-04")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let canvas = element(app, "drawingCanvas")
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        for line in 0..<3 { drawLine(line, on: canvas) }
        XCTAssertTrue(waitForStatus(app, containing: "strokes=12", timeout: 10), "status was: \(element(app, "testStatus").label)")

        let circle = element(app, "interruptEllipse")
        XCTAssertTrue(circle.waitForExistence(timeout: 20), "the scripted tutor circles line 2")
        let button = element(app, "notAMistakeButton")
        XCTAssertTrue(button.waitForExistence(timeout: 5), "the callout has a Not a mistake button")
        XCTAssertGreaterThanOrEqual(button.frame.height, 43.5, "44 pt tall, was \(button.frame.height)")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(button.frame.maxY, window.maxY - 20, "clear of the home-indicator strip at the bottom edge")
        XCTAssertGreaterThanOrEqual(button.frame.minX, 0)
        XCTAssertLessThanOrEqual(button.frame.maxX, window.maxX)
        screenshot("44-not-a-mistake-button-on-callout")

        // Drawing right beside the button, and on the hint words, still reaches the canvas.
        let beside = CGPoint(x: max(button.frame.minX - 90, 80), y: button.frame.midY)
        drawStroke(in: app, from: beside, to: CGPoint(x: beside.x + 40, y: beside.y + 8))
        XCTAssertTrue(waitForStatus(app, containing: "strokes=13", timeout: 10),
                      "a stroke beside the button is ink; status was: \(element(app, "testStatus").label)")
        let words = element(app, "hintText").frame
        drawStroke(in: app, from: CGPoint(x: words.minX + 20, y: words.midY), to: CGPoint(x: words.minX + 60, y: words.midY + 6))
        XCTAssertTrue(waitForStatus(app, containing: "strokes=14", timeout: 10),
                      "a stroke across the hint words is ink; status was: \(element(app, "testStatus").label)")
        XCTAssertTrue(circle.exists, "drawing did not dismiss the circle")

        button.tap()
        let gone = NSPredicate(format: "exists == false")
        let waiter = XCTNSPredicateExpectation(predicate: gone, object: circle)
        XCTAssertEqual(XCTWaiter().wait(for: [waiter], timeout: 10), .completed, "tapping the button takes the circle off")
        XCTAssertFalse(element(app, "hintText").exists)
        XCTAssertFalse(element(app, "notAMistakeButton").exists)
        screenshot("45-circle-dismissed")
    }
}
