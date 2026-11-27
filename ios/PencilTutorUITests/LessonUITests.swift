import XCTest

/// "Learn something new" (second row of a course's list, a one-field sheet, the lesson panel, Your turn, and the Lesson button on the
/// practice page). Run on CI (ios.yml) against the scripted tutor, launched with --silent; they attach screenshots as receipts.
/// Not run on the laptop.
final class LessonUITests: XCTestCase {
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

    private func startLesson(_ app: XCUIApplication, concept: String) {
        let row = element(app, "learnSomethingNewRow")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let field = element(app, "learnConceptField")
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the sheet has one text field")
        field.tap()
        field.typeText(concept)
        element(app, "learnStartButton").tap()
    }

    func testTheRowSitsUnderMyOwnProblemAndTheSheetNeedsAConcept() throws {
        let app = launchApp()
        openCourse(app)
        let ownRow = element(app, "ownProblemRow")
        let learnRow = element(app, "learnSomethingNewRow")
        let firstBankRow = element(app, "problem-u3-01")
        XCTAssertTrue(ownRow.waitForExistence(timeout: 10))
        XCTAssertTrue(learnRow.waitForExistence(timeout: 10))
        XCTAssertTrue(firstBankRow.waitForExistence(timeout: 10))
        XCTAssertLessThan(ownRow.frame.minY, learnRow.frame.minY, "Learn something new is under My own problem")
        XCTAssertLessThan(learnRow.frame.minY, firstBankRow.frame.minY, "and above the bank problems")
        XCTAssertGreaterThanOrEqual(learnRow.frame.height, 43.5, "a tap target of at least 44 pt")
        screenshot("50-learn-row-second")

        learnRow.tap()
        XCTAssertTrue(element(app, "learnConceptField").waitForExistence(timeout: 10))
        let start = element(app, "learnStartButton")
        // Behaviour, not isEnabled (misreported for disabled toolbar buttons on the iPadOS 26.5 simulator): an empty Start does nothing.
        start.tap()
        XCTAssertTrue(element(app, "learnConceptField").waitForExistence(timeout: 2), "Start with nothing typed leaves the sheet open")
        XCTAssertFalse(element(app, "lessonScreen").exists, "and opens no lesson")
        screenshot("51-learn-sheet-empty")
        element(app, "learnCancelButton").tap()
        XCTAssertTrue(learnRow.waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "learnConceptField").exists, "Cancel closed the sheet")
        XCTAssertFalse(element(app, "lessonScreen").exists, "and opened nothing")
    }

    func testStartShowsThePanelYourTurnOpensThePracticePageAndLessonReopensThePanel() throws {
        let app = launchApp()
        openCourse(app)
        startLesson(app, concept: "solving equations")

        XCTAssertTrue(element(app, "lessonPanel").waitForExistence(timeout: 20), "the lesson panel appears")
        let title = element(app, "lessonTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Undoing an operation")
        for step in 1...4 {
            XCTAssertTrue(element(app, "lessonStep-\(step)").exists, "step \(step) is on the panel")
        }
        XCTAssertTrue(element(app, "lessonExample").waitForExistence(timeout: 20), "the example appears once its check has passed")
        XCTAssertFalse(element(app, "lessonExamplePending").exists, "no \"Checking\" line left")
        screenshot("52-lesson-panel")

        let yourTurn = element(app, "lessonYourTurnButton")
        XCTAssertTrue(yourTurn.waitForExistence(timeout: 20), "Your turn appears once the practice problem is ready")
        XCTAssertGreaterThanOrEqual(yourTurn.frame.height, 43.5)
        yourTurn.tap()

        XCTAssertTrue(element(app, "drawingCanvas").waitForExistence(timeout: 15), "Your turn opens the practice page")
        let prompt = element(app, "problemPrompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        XCTAssertTrue(prompt.label.contains("3x + 2 = 14"), "the card shows the practice problem, was: \(prompt.label)")
        screenshot("53-practice-page")

        let lessonButton = element(app, "lessonButton")
        XCTAssertTrue(lessonButton.waitForExistence(timeout: 5), "the action pill has a Lesson button")
        XCTAssertFalse(element(app, "lessonSidePanel").exists)
        lessonButton.tap()
        XCTAssertTrue(element(app, "lessonSidePanel").waitForExistence(timeout: 5), "Lesson reopens the panel")
        XCTAssertTrue(element(app, "lessonTitle").exists)
        let close = element(app, "lessonCloseButton")
        XCTAssertGreaterThanOrEqual(close.frame.height, 43.5, "the close button is 44 pt")
        screenshot("54-lesson-side-panel")
        close.tap()
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: element(app, "lessonSidePanel"))], timeout: 5), .completed,
                       "the panel stays until the close button is tapped, then goes")

        element(app, "backButton").tap()
        XCTAssertTrue(element(app, "lessonPanel").waitForExistence(timeout: 10), "Back returns to the lesson")
    }

    func testAFollowUpIsAddedToThePanel() throws {
        let app = launchApp()
        openCourse(app)
        startLesson(app, concept: "solving equations")
        let field = element(app, "lessonFollowupField")
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("why undo the last one first")
        element(app, "lessonAskButton").tap()
        XCTAssertTrue(element(app, "lessonTurn-tutor").waitForExistence(timeout: 15), "the answer joins the panel")
        XCTAssertTrue(element(app, "lessonTurn-student").exists)
        screenshot("55-lesson-followup")
    }

    func testAConceptThatIsNotMathsIsRefused() throws {
        let app = launchApp()
        openCourse(app)
        startLesson(app, concept: "baking bread")
        let refused = element(app, "lessonRefused")
        XCTAssertTrue(refused.waitForExistence(timeout: 15))
        XCTAssertEqual(refused.label, "I can teach maths topics only.")
        XCTAssertFalse(element(app, "lessonYourTurnButton").exists)
        screenshot("56-lesson-refused")
    }
}
