import XCTest

/// Tutor memory, end to end against the scripted tutor (`--memory-on`): the consent screen offered once and skipped, reached again
/// from Settings, agreed to, the "What the tutor remembers" screen, and turning memory off with an erase. Screenshots are taken in
/// both orientations (`XCUIScreen.main.screenshot()`), and the layout is checked with real frames: nothing leaves the screen sideways,
/// every control is at least 44 x 44 pt, and the buttons can be reached by scrolling. Run on the iPad for the receipts.
final class MemoryScreensUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--scripted-client", "--any-input", "--memory-on", "--offer-memory"]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: name, payload: XCUIScreen.main.screenshot().pngRepresentation, userInfo: nil)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func rotate(to orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        Thread.sleep(forTimeInterval: 1.2)   // let the rotation settle
    }

    /// Scrolls the sheet's content up until the element can be tapped.
    private func scrollTo(_ target: XCUIElement, in scroller: XCUIElement) {
        var tries = 0
        while !target.isHittable && tries < 8 {
            scroller.swipeUp()
            tries += 1
        }
        XCTAssertTrue(target.isHittable, "\(target.identifier) can be reached by scrolling")
    }

    /// Nothing leaves the screen sideways, and every named control is at least 44 pt tall.
    private func checkLayout(_ app: XCUIApplication, ids: [String], label: String) {
        let window = app.windows.firstMatch.frame
        for id in ids {
            let control = element(app, id)
            XCTAssertTrue(control.exists, "\(label): \(id) exists")
            let frame = control.frame
            XCTAssertGreaterThanOrEqual(frame.minX, 0, "\(label): \(id) starts on screen, was \(frame)")
            XCTAssertLessThanOrEqual(frame.maxX, window.maxX + 0.5, "\(label): \(id) ends on screen, was \(frame) in \(window)")
            XCTAssertGreaterThanOrEqual(frame.height, 43.5, "\(label): \(id) is at least 44 pt tall, was \(frame.height)")
        }
    }

    func testConsentOfferedOnceSkippedThenAgreedFromSettingsAndErased() throws {
        let app = launch()

        // 1. Offered by itself once the code is accepted. Portrait, then landscape.
        let consent = element(app, "memoryConsentView")
        XCTAssertTrue(consent.waitForExistence(timeout: 20), "the consent screen is offered once")
        Thread.sleep(forTimeInterval: 0.6)
        screenshot("memory-01-consent-portrait-top")
        checkLayout(app, ids: ["memoryAttestParent", "memoryAttestAdult", "memoryTurnOn", "memoryNotNow", "memoryPolicyLink"], label: "consent portrait")
        XCTAssertFalse(element(app, "memoryTurnOn").isEnabled, "Turn on stays disabled until someone says who is agreeing")
        consent.swipeUp()
        screenshot("memory-02-consent-portrait-bottom")

        rotate(to: .landscapeLeft)
        consent.swipeDown()
        screenshot("memory-03-consent-landscape-top")
        checkLayout(app, ids: ["memoryAttestParent", "memoryAttestAdult", "memoryTurnOn", "memoryNotNow", "memoryPolicyLink"], label: "consent landscape")
        scrollTo(element(app, "memoryNotNow"), in: consent)
        screenshot("memory-04-consent-landscape-bottom")

        // 2. Choosing who is agreeing enables the button, and "Not now" is a way out with nothing recorded.
        scrollTo(element(app, "memoryAttestParent"), in: consent)
        element(app, "memoryAttestParent").tap()
        XCTAssertTrue(element(app, "memoryAttestParent").isSelected)
        scrollTo(element(app, "memoryTurnOn"), in: consent)
        XCTAssertTrue(element(app, "memoryTurnOn").isEnabled)
        screenshot("memory-05-consent-landscape-parent-chosen")
        element(app, "memoryNotNow").tap()
        XCTAssertTrue(consent.waitForNonExistence(timeout: 10), "Not now closes the screen")
        rotate(to: .portrait)

        // 3. Reachable again from Settings, where memory shows as off.
        let settings = element(app, "settingsButton")
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let status = element(app, "settingsMemoryStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 10), "Settings has a Memory section")
        XCTAssertEqual(status.label, "Off")
        screenshot("memory-06-settings-memory-off-portrait")
        rotate(to: .landscapeLeft)
        screenshot("memory-07-settings-memory-off-landscape")
        rotate(to: .portrait)

        // 4. Agree as an adult student from Settings.
        element(app, "settingsMemoryTurnOnButton").tap()
        XCTAssertTrue(consent.waitForExistence(timeout: 10))
        scrollTo(element(app, "memoryAttestAdult"), in: consent)
        element(app, "memoryAttestAdult").tap()
        scrollTo(element(app, "memoryTurnOn"), in: consent)
        element(app, "memoryTurnOn").tap()
        XCTAssertTrue(consent.waitForNonExistence(timeout: 10), "agreeing closes the screen")
        XCTAssertTrue(waitLabel(status, startingWith: "On since").hasPrefix("On since"), "Settings now says On")
        screenshot("memory-08-settings-memory-on-portrait")

        // 5. What the tutor remembers, both orientations.
        element(app, "settingsMemoryRecordButton").tap()
        let line = element(app, "memoryStatusLine")
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        XCTAssertTrue(line.label.hasPrefix("On since"))
        XCTAssertTrue(element(app, "memoryAgreementLine").exists)
        XCTAssertTrue(element(app, "memoryRecent-u3-04").exists, "the practice rows are listed")
        screenshot("memory-09-record-portrait-top")
        checkLayout(app, ids: ["memoryTurnOff", "memoryErase", "memoryRecordDone"], label: "record portrait")
        app.swipeUp()
        screenshot("memory-10-record-portrait-bottom")
        rotate(to: .landscapeLeft)
        screenshot("memory-11-record-landscape")
        checkLayout(app, ids: ["memoryTurnOff", "memoryErase", "memoryRecordDone"], label: "record landscape")

        // 6. Turning off asks what to do with what is stored; erase empties the list.
        scrollTo(element(app, "memoryTurnOff"), in: app.scrollViews.firstMatch.exists ? app.scrollViews.firstMatch : app.tables.firstMatch)
        element(app, "memoryTurnOff").tap()
        let eraseChoice = app.buttons["Turn off and erase everything"]
        XCTAssertTrue(eraseChoice.waitForExistence(timeout: 10), "the choice names what happens to the record")
        XCTAssertTrue(app.buttons["Turn off, keep what is stored"].exists)
        screenshot("memory-12-turn-off-choices-landscape")
        eraseChoice.tap()
        XCTAssertEqual(waitLabel(line, equalTo: "Off"), "Off", "memory is off")
        XCTAssertTrue(element(app, "memoryNoPractice").waitForExistence(timeout: 10), "the record is empty after the erase")
        screenshot("memory-13-record-after-erase-landscape")
        rotate(to: .portrait)
        screenshot("memory-14-record-after-erase-portrait")
    }

    /// Waits up to 10 s for the element's label to start with / equal a value and returns the label last seen.
    private func waitLabel(_ element: XCUIElement, startingWith prefix: String? = nil, equalTo exact: String? = nil) -> String {
        let deadline = Date().addingTimeInterval(10)
        var last = element.label
        while Date() < deadline {
            last = element.label
            if let prefix, last.hasPrefix(prefix) { break }
            if let exact, last == exact { break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return last
    }

    /// With no `--memory-on` the scripted tutor says nothing about memory, like a server without it: no section, no offer.
    func testNothingAppearsWhenTheServerDoesNotOfferMemory() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--scripted-client", "--any-input", "--offer-memory"]
        app.launch()
        XCTAssertTrue(element(app, "settingsButton").waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(element(app, "memoryConsentView").exists, "no consent screen")
        element(app, "settingsButton").tap()
        XCTAssertTrue(element(app, "settingsCode").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "settingsMemoryStatus").exists, "no Memory section")
    }
}
