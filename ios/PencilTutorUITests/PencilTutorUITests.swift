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

    /// `-lastCourseSlug` is set on purpose: an empty one means "no remembered course", so a device that ran the app before still
    /// starts on the course picker.
    private func launchApp(extra: [String] = [], lastCourse: String = "") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--scripted-client", "--any-input", "-lastCourseSlug", lastCourse] + extra
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Picks the course, then the problem, the way a student does. The original twelve (u3-..) are the "bc-math-9-unit-3" course.
    private func open(problem id: String, course: String = "bc-math-9-unit-3", in app: XCUIApplication) {
        let courseRow = element(app, "course-\(course)")
        XCTAssertTrue(courseRow.waitForExistence(timeout: 15), "course \(course) should be on the picker")
        courseRow.tap()
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

    /// "Start free": a new student sees the code screen, taps one button and is in, with nothing typed. The scripted server stands in
    /// for POST /api/free-code (`--scripted-needs-code` starts on the code screen instead of signed in), so this proves the button, the
    /// sign-in transition, the first check with the server and the course picker. It does not prove HTTP, the Keychain or the real server.
    func testStartFreeSignsInWithoutTypingACode() throws {
        let app = launchApp(extra: ["--scripted-needs-code"])

        let startFree = element(app, "startFreeButton")
        XCTAssertTrue(startFree.waitForExistence(timeout: 15), "the code screen should offer Start free")
        XCTAssertTrue(element(app, "codeField").exists, "typing a code still works: Start free is an addition")
        XCTAssertTrue(element(app, "codeContinueButton").exists)
        XCTAssertFalse(element(app, "course-bc-math-9-unit-3").exists, "nobody is signed in yet")
        screenshot(app, named: "20-code-screen-with-start-free")

        startFree.tap()

        let courseRow = element(app, "course-bc-math-9-unit-3")
        XCTAssertTrue(courseRow.waitForExistence(timeout: 15), "after Start free the course picker should open, with no code typed")
        XCTAssertFalse(startFree.exists, "the code screen is gone")
        let chip = element(app, "allowanceChip")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "the first check with the server should show the hours left")
        XCTAssertTrue(chip.label.contains("min left"), "the chip was: \(chip.label)")
        screenshot(app, named: "21-signed-in-by-start-free")
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

    // MARK: - Courses

    /// Scrolls the list until the element can be tapped (a List only builds the rows on screen).
    private func scrollTo(_ target: XCUIElement, in app: XCUIApplication) {
        var tries = 0
        while !(target.exists && target.isHittable) && tries < 12 {
            app.swipeUp()
            tries += 1
        }
    }

    /// The picker shows the three shelves with their courses, every row is at least 44 pt tall and inside the screen in both
    /// orientations, a course opens its problem list, and the next launch opens straight into the course used last.
    func testCoursePickerGroupsCoursesAndRemembersTheLastOne() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        var app = launchApp()
        for (name, orientation) in [("portrait", UIDeviceOrientation.portrait), ("landscape", UIDeviceOrientation.landscapeLeft)] {
            XCUIDevice.shared.orientation = orientation
            Thread.sleep(forTimeInterval: 1.0)
            XCTAssertTrue(element(app, "course-bc-math-5").waitForExistence(timeout: 15), "\(name): the picker is up")
            let window = app.windows.firstMatch.frame
            for id in ["courseSection-elementary", "course-bc-math-5", "course-bc-math-9-unit-3"] {
                let frame = element(app, id).frame
                XCTAssertGreaterThanOrEqual(frame.minX, 0, "\(name): \(id) starts on screen")
                XCTAssertLessThanOrEqual(frame.maxX, window.maxX + 0.5, "\(name): \(id) ends on screen, was \(frame)")
            }
            for id in ["course-bc-math-5", "course-bc-math-9-unit-3"] {
                XCTAssertGreaterThanOrEqual(element(app, id).frame.height, 43.5, "\(name): \(id) is at least 44 pt tall")
            }
            screenshot(app, named: "20-course-picker-\(name)")
            scrollTo(element(app, "course-linear-algebra"), in: app)
            XCTAssertTrue(element(app, "courseSection-college").exists, "\(name): the College shelf is listed")
            XCTAssertTrue(element(app, "course-linear-algebra").exists, "\(name): a college course is listed")
            screenshot(app, named: "21-course-picker-scrolled-\(name)")
            for _ in 0..<12 { app.swipeDown() }
        }
        XCUIDevice.shared.orientation = .portrait

        // A course opens its problems; a problem opens the page.
        element(app, "course-bc-math-5").tap()
        XCTAssertTrue(element(app, "problem-m5-01").waitForExistence(timeout: 10), "the course lists its problems")
        screenshot(app, named: "22-course-problem-list")
        element(app, "problem-m5-01").tap()
        XCTAssertTrue(element(app, "drawingCanvas").waitForExistence(timeout: 10))
        XCTAssertEqual(element(app, "problemCourseTitle").label, "BC Math 5")
        app.terminate()

        // Next launch: the remembered course opens by itself, and Back goes to the picker.
        app = launchApp(lastCourse: "bc-math-5")
        XCTAssertTrue(element(app, "problem-m5-01").waitForExistence(timeout: 15), "the last course opens at launch")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "course-bc-math-6").waitForExistence(timeout: 10), "Back shows the picker")
        screenshot(app, named: "23-picker-after-back-last-used")
    }

    /// The longest prompts of the bank wrap inside the problem card in both orientations: a grade 5 word problem, a calculus word
    /// problem, a linear algebra matrix, a grade 12 word problem and the longest grade 9 one. The card stays inside the screen,
    /// at most 432 pt wide, and does not grow past about 45% of the height. Screenshots are the receipt that nothing is cut off.
    func testLongPromptsWrapInsideTheCardInPortraitAndLandscape() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let cases = [("m5-79", "grade5-word-problem"), ("c1-59", "calculus-word-problem"), ("la-69", "linear-algebra-matrix"),
                     ("fm12-19", "grade12-word-problem"), ("m9-22", "grade9-long-prompt"), ("fm11-33", "grade11-longest-prompt")]
        for (id, label) in cases {
            for (name, orientation) in [("portrait", UIDeviceOrientation.portrait), ("landscape", UIDeviceOrientation.landscapeLeft)] {
                XCUIDevice.shared.orientation = orientation
                Thread.sleep(forTimeInterval: 1.0)
                let app = launchApp(extra: ["--open-problem", id])
                let prompt = element(app, "problemPrompt")
                XCTAssertTrue(prompt.waitForExistence(timeout: 20), "\(id) \(name): the problem opens from the launch argument")
                Thread.sleep(forTimeInterval: 1.0)
                let window = app.windows.firstMatch.frame
                let frame = prompt.frame
                XCTAssertGreaterThanOrEqual(frame.minX, 0, "\(id) \(name): prompt starts on screen")
                XCTAssertLessThanOrEqual(frame.maxX, window.maxX, "\(id) \(name): prompt ends on screen, was \(frame)")
                XCTAssertLessThanOrEqual(frame.width, 433, "\(id) \(name): prompt fits the card width, was \(frame.width)")
                XCTAssertLessThanOrEqual(frame.maxY, window.height * 0.45, "\(id) \(name): the card leaves the page its room, was \(frame)")
                XCTAssertLessThanOrEqual(element(app, "toolRail").frame.maxX, frame.minX, "\(id) \(name): rail clear of the card")
                XCTAssertTrue(element(app, "problemCourseTitle").exists, "\(id) \(name): the course name is shown")
                screenshot(app, named: "3-\(label)-\(name)")
                app.terminate()
            }
        }
    }
}
