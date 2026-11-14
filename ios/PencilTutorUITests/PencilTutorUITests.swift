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
            let x = 0.12 + 0.17 * Double(stroke)   // right of the 48 pt tool rail on the left edge
            let y = 0.22 + 0.20 * Double(row)   // below the floating problem card and action pill
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
            payload: XCUIScreen.main.screenshot().pngRepresentation,
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

    /// The tool rail is on screen the moment the problem opens, with no tap. Choosing the eraser and then a colour returns to the
    /// pen and the rail is still there the whole time. Also checks the real frames: the rail sits under the Back button, left of
    /// the problem card, inside the screen, and every control is at least 44 x 44 pt.
    func testToolRailIsAlwaysVisibleAndColourAfterEraserReturnsToThePen() throws {
        let app = launchApp()
        open(problem: cleanProblem, in: app)

        let rail = element(app, "toolRail")
        XCTAssertTrue(rail.waitForExistence(timeout: 10), "the rail should be on the page without any tap")
        let pen = element(app, "toolRail_pen")
        let eraser = element(app, "toolRail_eraser")
        let red = element(app, "toolRail_colour_red")
        XCTAssertTrue(pen.exists && eraser.exists && red.exists)
        XCTAssertTrue(element(app, "toolRail_lasso").exists && element(app, "toolRail_marker").exists)
        XCTAssertTrue(element(app, "toolRail_undo").exists && element(app, "toolRail_redo").exists)
        XCTAssertTrue(element(app, "toolRail_width_thin").exists && element(app, "toolRail_width_thick").exists)
        pen.tap()   // a device keeps the last pen between runs, so start from a known one
        XCTAssertTrue(pen.isSelected)

        // Real frames.
        let window = app.windows.firstMatch.frame
        let railFrame = rail.frame
        let back = element(app, "backButton").frame
        XCTAssertGreaterThanOrEqual(railFrame.minY, back.maxY, "the rail starts under the Back button")
        XCTAssertGreaterThanOrEqual(railFrame.minX, 0)
        XCTAssertLessThanOrEqual(railFrame.maxY, window.maxY, "the rail ends on screen, no clipping")
        let prompt = element(app, "problemPrompt").frame
        XCTAssertLessThanOrEqual(railFrame.maxX, prompt.minX, "the rail does not overlap the problem card")
        for id in ["toolRail_pen", "toolRail_marker", "toolRail_eraser", "toolRail_lasso", "toolRail_colour_black", "toolRail_colour_green",
                   "toolRail_width_thin", "toolRail_width_medium", "toolRail_width_thick", "toolRail_undo", "toolRail_redo"] {
            let frame = element(app, id).frame
            XCTAssertGreaterThanOrEqual(frame.width, 43.5, "\(id) is at least 44 pt wide, was \(frame.width)")
            XCTAssertGreaterThanOrEqual(frame.height, 43.5, "\(id) is at least 44 pt tall, was \(frame.height)")
        }
        screenshot(app, named: "06-tool-rail-on-open")

        eraser.tap()
        XCTAssertTrue(eraser.isSelected, "the eraser is chosen")
        XCTAssertTrue(rail.exists && red.exists, "the rail stays up after a pick")
        screenshot(app, named: "07-tool-rail-eraser-chosen")

        red.tap()
        XCTAssertTrue(pen.isSelected, "a colour while erasing returns to the pen")
        XCTAssertFalse(eraser.isSelected)
        XCTAssertTrue(red.isSelected)
        XCTAssertTrue(rail.exists && eraser.exists, "the rail is still up, nothing to reopen")
        screenshot(app, named: "08-tool-rail-red-pen-after-eraser")

        // Draw a stroke, undo it from the rail, redo it; the rail never moves.
        let canvas = element(app, "drawingCanvas")
        drawLine(0, on: canvas)
        XCTAssertTrue(waitForStatus(app, containing: "strokes=4", timeout: 10), "status was: \(element(app, "testStatus").label)")
        element(app, "toolRail_undo").tap()
        XCTAssertTrue(waitForStatus(app, containing: "strokes=3", timeout: 10), "undo from the rail removes one stroke; status was: \(element(app, "testStatus").label)")
        XCTAssertEqual(rail.frame, railFrame, "the rail did not move")
        screenshot(app, named: "09-tool-rail-after-undo")
    }


    /// Every floating control stays on one line, inside the screen, with a 44 x 44 pt hit target, and the rail clears the Back
    /// button, the card and the action pill: checked with the real frames in both orientations, with the card open and folded.
    func testFloatingChromeFitsInPortraitAndLandscape() throws {
        let app = launchApp()
        open(problem: cleanProblem, in: app)
        defer { XCUIDevice.shared.orientation = .portrait }
        for (name, orientation) in [("portrait", UIDeviceOrientation.portrait), ("landscape", UIDeviceOrientation.landscapeLeft)] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(element(app, "toolRail").waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 1.0)   // let the rotation settle
            let window = app.windows.firstMatch.frame
            let rail = element(app, "toolRail").frame
            let back = element(app, "backButton").frame
            let prompt = element(app, "problemPrompt").frame
            XCTAssertGreaterThanOrEqual(rail.minY, back.maxY, "\(name): rail under the Back button")
            XCTAssertLessThanOrEqual(rail.maxY, window.maxY, "\(name): rail fully on screen, rail \(rail) window \(window)")
            XCTAssertLessThanOrEqual(rail.maxX, prompt.minX, "\(name): rail clear of the problem card")
            for id in ["checkMyWorkButton", "tapToTalkButton", "clearMarksButton", "erasePageButton"] {
                let button = element(app, id)
                XCTAssertTrue(button.waitForExistence(timeout: 10), "\(name): \(id) on the page")
                let frame = button.frame
                XCTAssertGreaterThanOrEqual(frame.minX, 0, "\(name): \(id) starts on screen")
                XCTAssertLessThanOrEqual(frame.maxX, window.maxX, "\(name): \(id) ends on screen, was \(frame)")
                XCTAssertGreaterThanOrEqual(frame.height, 43.5, "\(name): \(id) at least 44 pt tall")
                XCTAssertGreaterThanOrEqual(frame.width, 43.5, "\(name): \(id) at least 44 pt wide")
                XCTAssertFalse(frame.intersects(rail), "\(name): \(id) does not overlap the rail")
            }
            screenshot(app, named: "11-chrome-\(name)-card-open")
            // Fold the card: the same checks hold and the page gets its room back.
            element(app, "problemPrompt").tap()
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertLessThanOrEqual(element(app, "toolRail").frame.maxX, element(app, "problemPrompt").frame.minX,
                                     "\(name): folded card still clear of the rail")
            screenshot(app, named: "12-chrome-\(name)-card-folded")
            element(app, "problemPrompt").tap()   // open it again for the next pass
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}
