import XCTest

/// Show me how: the button on a bank problem, the panel with its steps and answer, Try one like it swapping the page to a checked
/// practice problem that takes ink and gets a look, and the "I couldn't work this one out with confidence" state for a typed problem.
/// Run on CI (ios.yml) against the scripted tutor, launched with --silent; they attach screenshots as receipts. Not run on the laptop.
final class ShowMeUITests: XCTestCase {
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

    private func drawLine(_ row: Int, on canvas: XCUIElement) {
        for stroke in 0..<4 {
            let x = 0.12 + 0.17 * Double(stroke)
            let y = 0.22 + 0.20 * Double(row)
            let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
            let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: x + 0.12, dy: y + 0.03))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    func testShowMeHowThenTryOneLikeItSwapsThePageToAPracticeProblemThatTakesInkAndGetsALook() throws {
        let app = launchApp()
        openCourse(app)
        let row = element(app, "problem-u3-01")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let canvas = element(app, "drawingCanvas")
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))

        let button = element(app, "showMeHowButton")
        XCTAssertTrue(button.waitForExistence(timeout: 10), "every problem page has Show me how in the action pill")
        XCTAssertGreaterThanOrEqual(button.frame.height, 43.5, "a tap target of at least 44 pt")
        screenshot("60-show-me-how-button")
        button.tap()

        // The close button (its own identifier) marks the panel: the container's own identifier is not exposed under the side panel's.
        XCTAssertTrue(element(app, "showMeCloseButton").waitForExistence(timeout: 10), "the panel opens")
        XCTAssertTrue(element(app, "showMeStep-1").waitForExistence(timeout: 15), "the steps appear")
        XCTAssertTrue(element(app, "showMeStep-2").exists)
        XCTAssertTrue(element(app, "showMeAnswer").exists, "and the answer")
        XCTAssertGreaterThanOrEqual(element(app, "showMeCloseButton").frame.height, 43.5, "the close button is 44 pt")
        screenshot("61-show-me-how-panel")

        let tryOne = element(app, "tryOneLikeItButton")
        XCTAssertTrue(tryOne.waitForExistence(timeout: 5), "Try one like it is at the bottom of the panel")
        XCTAssertGreaterThanOrEqual(tryOne.frame.height, 43.5)
        tryOne.tap()

        let prompt = element(app, "problemPrompt")
        let swapped = NSPredicate(format: "label CONTAINS %@", "3x + 2 = 14")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: swapped, object: prompt)], timeout: 20), .completed,
                       "the page becomes the practice problem; the card says: \(prompt.label)")
        XCTAssertFalse(element(app, "showMeCloseButton").exists, "a new page starts without the old panel")
        screenshot("62-practice-page-after-try-one-like-it")

        let page = element(app, "drawingCanvas")
        for line in 0..<2 { drawLine(line, on: page) }
        XCTAssertTrue(waitForStatus(app, containing: "strokes=8", timeout: 10), "status was: \(element(app, "testStatus").label)")
        XCTAssertTrue(waitForStatus(app, containing: "last=wait", timeout: 20), "the swapped page gets a look; status was: \(element(app, "testStatus").label)")
        screenshot("63-practice-page-took-ink-and-got-a-look")

        element(app, "showMeHowButton").tap()
        XCTAssertTrue(element(app, "showMeStep-1").waitForExistence(timeout: 15), "Show me how works on the practice page too")
    }

    func testATypedProblemTheTutorCannotCheckSaysSoAndOffersTryAgainWithNoSteps() throws {
        let app = launchApp()
        openCourse(app)
        let ownRow = element(app, "ownProblemRow")
        XCTAssertTrue(ownRow.waitForExistence(timeout: 10))
        ownRow.tap()
        let field = element(app, "ownProblemField")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("x + 1 = 2, no confident answer")
        element(app, "ownProblemStartButton").tap()
        XCTAssertTrue(element(app, "drawingCanvas").waitForExistence(timeout: 15))

        let button = element(app, "showMeHowButton")
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()

        XCTAssertTrue(element(app, "showMeNotChecked").waitForExistence(timeout: 15), "the panel says it could not work this one out")
        XCTAssertFalse(element(app, "showMeStep-1").exists, "nothing unchecked is shown")
        XCTAssertFalse(element(app, "tryOneLikeItButton").exists, "and there is nothing to build a problem on")
        XCTAssertTrue(element(app, "showMeRetryButton").exists, "Try again is offered")
        screenshot("64-show-me-how-not-checked")
        element(app, "showMeCloseButton").tap()
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: element(app, "showMeCloseButton"))], timeout: 5), .completed,
                       "the panel stays until the close button is tapped, then goes")
    }
}
