import PencilKit
import XCTest
@testable import PencilTutor

final class WireAndSnapshotTests: XCTestCase {
    private func jsonObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testWatchRequestUsesTheServerFieldNames() throws {
        let request = WatchRequest(
            sessionId: "s1", problemId: "u3-04", drawingRevision: 17,
            imagePngBase64: "AAAA", imageWidth: 800, imageHeight: 600,
            lines: [LineWire(index: 1, box: BoxWire(x: 10, y: 40, w: 300, h: 30), lastStrokeAt: "2026-11-13T01:00:00Z")],
            history: [HistoryWire(at: "t", action: "interrupt", line: 2, hintWritten: "Check the signs")],
            clientTime: "2026-11-13T01:00:05Z"
        )
        let object = try jsonObject(request)
        XCTAssertEqual(Set(object.keys), [
            "session_id", "problem_id", "drawing_revision", "image_png_base64",
            "image_width", "image_height", "lines", "history", "client_time"
        ])
        XCTAssertEqual(object["drawing_revision"] as? Int, 17)
        let line = try XCTUnwrap((object["lines"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(line.keys), ["index", "box", "last_stroke_at"])
        let history = try XCTUnwrap((object["history"] as? [[String: Any]])?.first)
        XCTAssertEqual(history["hint_written"] as? String, "Check the signs")
    }

    func testAskRequestSendsExactlyTheFieldsInTheServerReadme() throws {
        let request = AskRequest(sessionId: "s1", problemId: "u3-04", drawingRevision: 4, audioBase64: "AAAA", imagePngBase64: "BBBB")
        let object = try jsonObject(request)
        XCTAssertEqual(Set(object.keys), ["session_id", "problem_id", "drawing_revision", "audio_base64", "image_png_base64"])
    }

    func testWatchResponseDecodesInterruptAndWait() throws {
        let interrupt = #"{"action":"interrupt","line":2,"reason":"r","hint_spoken":"Look again.","hint_written":"Check the signs here","drawing_revision":17,"model":"m","latency_ms":5200,"request_id":"abc"}"#
        let decoded = try JSONDecoder().decode(WatchResponse.self, from: Data(interrupt.utf8))
        XCTAssertEqual(decoded.action, "interrupt")
        XCTAssertEqual(decoded.line, 2)
        XCTAssertEqual(decoded.hintWritten, "Check the signs here")
        XCTAssertEqual(decoded.drawingRevision, 17)
        XCTAssertEqual(decoded.latencyMs, 5200)

        let wait = #"{"action":"wait","line":null,"reason":"fine","hint_spoken":null,"hint_written":null,"drawing_revision":17,"model":"m","latency_ms":10,"request_id":"x"}"#
        let waited = try JSONDecoder().decode(WatchResponse.self, from: Data(wait.utf8))
        XCTAssertEqual(waited.action, "wait")
        XCTAssertNil(waited.line)
    }

    func testRepliesCarryTheAllowanceWhenTheServerSendsOne() throws {
        let allowance = #""allowance":{"month":"2026-11","used_seconds":120,"cap_seconds":28800,"remaining_seconds":28680,"remaining_minutes":478,"percent_used":0.4,"state":"ok","notice":null}"#
        let watch = #"{"action":"wait","line":null,"reason":"fine","hint_spoken":null,"hint_written":null,"drawing_revision":3,"model":"m","latency_ms":10,"request_id":"x",\#(allowance)}"#
        XCTAssertEqual(try JSONDecoder().decode(WatchResponse.self, from: Data(watch.utf8)).allowance?.remainingMinutes, 478)

        let ask = #"{"transcript":"t","answer_text":"a","model":"m","latency_ms":1,"request_id":"r",\#(allowance)}"#
        XCTAssertEqual(try JSONDecoder().decode(AskResponse.self, from: Data(ask.utf8)).allowance?.state, .ok)

        let consult = #"{"answer_text":"a","model":"m","latency_ms":1,"request_id":"r",\#(allowance)}"#
        XCTAssertNotNil(try JSONDecoder().decode(ConsultResponse.self, from: Data(consult.utf8)).allowance)

        let live = #"{"session_id":"s","sdp":"v=0","model":"m","voice":"v","latency_ms":1,"request_id":"r",\#(allowance)}"#
        XCTAssertNotNil(try JSONDecoder().decode(LiveSessionResponse.self, from: Data(live.utf8)).allowance)

        // A server that sends none (older build, scripted mode) is fine too.
        let bare = #"{"transcript":"t","answer_text":"a"}"#
        XCTAssertNil(try JSONDecoder().decode(AskResponse.self, from: Data(bare.utf8)).allowance)
    }

    func testErrorBodyCarriesTheAllowance() throws {
        let body = #"{"error":"hours_used_up","reason":"month_cap_reached","request_id":"r","allowance":{"month":"2026-11","used_seconds":28800,"cap_seconds":28800,"remaining_seconds":0,"remaining_minutes":0,"percent_used":100,"state":"used_up","notice":null}}"#
        let decoded = try JSONDecoder().decode(ServerErrorBody.self, from: Data(body.utf8))
        XCTAssertEqual(decoded.error, "hours_used_up")
        XCTAssertEqual(decoded.allowance?.state, .usedUp)
    }

    func testSpeakRequestLeavesTheTextOutForTheAllowanceNotices() throws {
        let notice = try jsonObject(SpeakRequest(sessionId: "s1", text: nil, purpose: "allowance_low"))
        XCTAssertEqual(Set(notice.keys), ["session_id", "purpose"], "the server composes these two sentences itself")
        let normal = try jsonObject(SpeakRequest(sessionId: "s1", text: "Check the signs.", purpose: "hint"))
        XCTAssertEqual(Set(normal.keys), ["session_id", "text", "purpose"])
    }

    func testScriptedClientAnswersMeAndHeartbeatWithAHealthyAllowance() async throws {
        let client = ScriptedTutorClient()
        let me = try await client.me()
        XCTAssertFalse(me.plan.live, "live voice is off by default")
        XCTAssertEqual(me.allowance.state, .ok)
        let beat = try await client.heartbeat(HeartbeatRequest(sessionId: "s", problemId: "u3-04"))
        XCTAssertTrue(beat.ok)
    }

    func testAskResponseDecodes() throws {
        let body = #"{"transcript":"what next","answer_text":"Try dividing by 3.","model":"m","latency_ms":3000,"request_id":"r"}"#
        let decoded = try JSONDecoder().decode(AskResponse.self, from: Data(body.utf8))
        XCTAssertEqual(decoded.answerText, "Try dividing by 3.")
        XCTAssertEqual(decoded.transcript, "what next")
    }

    func testScriptedClientMirrorsTheServerScript() async throws {
        func request(problem: String, lines: [Int], history: [HistoryWire] = []) -> WatchRequest {
            WatchRequest(
                sessionId: "s", problemId: problem, drawingRevision: 5, imagePngBase64: "", imageWidth: 1, imageHeight: 1,
                lines: lines.map { LineWire(index: $0, box: BoxWire(x: 0, y: 0, w: 1, h: 1), lastStrokeAt: "t") },
                history: history, clientTime: "t"
            )
        }
        let client = ScriptedTutorClient()

        let planted = try await client.watch(request(problem: "u3-04", lines: [1, 2, 3]))
        XCTAssertEqual(planted.action, "interrupt")
        XCTAssertEqual(planted.line, 2)
        XCTAssertEqual(planted.drawingRevision, 5, "the revision must be echoed")

        let onlyOneLine = try await client.watch(request(problem: "u3-04", lines: [1]))
        XCTAssertEqual(onlyOneLine.action, "wait")

        let repeated = try await client.watch(request(
            problem: "u3-04", lines: [1, 2],
            history: [HistoryWire(at: "t", action: "interrupt", line: 2, hintWritten: "x")]
        ))
        XCTAssertEqual(repeated.action, "wait", "no second interrupt on line 2")

        let clean = try await client.watch(request(problem: "u3-01", lines: [1, 2, 3]))
        XCTAssertEqual(clean.action, "wait")
    }

    func testSnapshotIsSmallAndNumbersTheLines() throws {
        var points: [PKStrokePoint] = []
        for step in 0..<20 {
            let location = CGPoint(x: 100 + CGFloat(step) * 30, y: 200 + CGFloat(step % 3) * 8)
            points.append(PKStrokePoint(location: location, timeOffset: Double(step) * 0.01,
                                        size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: path)
        let drawing = PKDrawing(strokes: [stroke])
        let strokes = TutorSession.inkStrokes(from: drawing)
        XCTAssertEqual(strokes.count, 1)
        let lines = LineGrouper().group(strokes)
        XCTAssertEqual(lines.count, 1)

        let canvas = CGSize(width: 1180, height: 820)
        let snapshot = try PageSnapshotter.make(drawing: drawing, canvasSize: canvas, lines: lines)

        XCTAssertLessThanOrEqual(snapshot.png.count, PageSnapshotter.maxBytes)
        XCTAssertLessThanOrEqual(max(snapshot.pixelWidth, snapshot.pixelHeight), 1024)
        XCTAssertGreaterThan(snapshot.pixelWidth, 800, "should be close to the 1024 limit, not tiny")
        XCTAssertEqual(Array(snapshot.png.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "PNG signature")
        XCTAssertEqual(snapshot.scale, 1024 / 1180, accuracy: 0.0001)

        let wire = LineWire(lines[0], scale: snapshot.scale)
        XCTAssertEqual(wire.box.x, Double(lines[0].box.minX * snapshot.scale), accuracy: 0.001)
    }

    // MARK: - The endless page

    /// A short horizontal-ish pen stroke whose left end is at (x, y), for building pages in tests.
    private func penStroke(x: CGFloat, y: CGFloat) -> PKStroke {
        var points: [PKStrokePoint] = []
        for step in 0..<12 {
            points.append(PKStrokePoint(location: CGPoint(x: x + CGFloat(step) * 20, y: y + CGFloat(step % 3) * 6),
                                        timeOffset: Double(step) * 0.01, size: CGSize(width: 4, height: 4),
                                        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    func testPageThatFitsTheFirstScreenGetsTheSamePictureAsBefore() {
        let screen = CGSize(width: 1180, height: 820)
        let short = PageSnapshotter.region(canvasSize: screen, inkBottom: 600)
        XCTAssertEqual(short.rect, CGRect(x: 0, y: 0, width: 1180, height: 820))
        XCTAssertEqual(short.scale, 1024 / 1180, accuracy: 0.0001, "the old rule: longer side of the screen at 1024 px")
        let empty = PageSnapshotter.region(canvasSize: screen, inkBottom: nil)
        XCTAssertEqual(empty.rect, short.rect)
        // Ink 10 pt from the bottom edge still fits: its 40 pt margin is blank paper, not a reason to grow the picture.
        XCTAssertEqual(PageSnapshotter.region(canvasSize: screen, inkBottom: 780).rect.height, 820)
    }

    func testPictureGrowsDownToTheLowestInkAndShrinksToStayWithin1024Pixels() {
        let screen = CGSize(width: 1180, height: 820)
        let region = PageSnapshotter.region(canvasSize: screen, inkBottom: 1500)
        XCTAssertEqual(region.rect.minY, 0)
        XCTAssertEqual(region.rect.maxY, 1540, accuracy: 0.001, "lowest ink plus the 40 pt margin")
        XCTAssertEqual(region.scale, 1024 / 1540, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(region.rect.height * region.scale, 1024.001)
        XCTAssertLessThanOrEqual(region.rect.width * region.scale, 1024.001)
    }

    func testVeryLongPageSlidesTheWindowInsteadOfShrinkingPastLegible() {
        let screen = CGSize(width: 1180, height: 820)
        let region = PageSnapshotter.region(canvasSize: screen, inkBottom: 4000)
        XCTAssertEqual(region.scale, PageSnapshotter.minLegibleScale, accuracy: 0.0001)
        XCTAssertEqual(region.rect.maxY, 4040, accuracy: 0.001, "the window ends under the lowest ink")
        XCTAssertEqual(region.rect.height, 1024 / PageSnapshotter.minLegibleScale, accuracy: 0.01)
        XCTAssertEqual(region.rect.minY, 4040 - region.rect.height, accuracy: 0.01)
        XCTAssertLessThanOrEqual(region.rect.height * region.scale, 1024.001)
    }

    func testLongPageSnapshotCoversTheLowInkAndLineBoxesAreMeasuredFromThePictureTop() throws {
        var strokes: [PKStroke] = []
        for row in 0..<3 { strokes.append(penStroke(x: 100, y: 200 + CGFloat(row) * 40)) }   // near the top
        strokes.append(penStroke(x: 100, y: 1500))                                            // two screens down
        let drawing = PKDrawing(strokes: strokes)
        let lines = LineGrouper().group(TutorSession.inkStrokes(from: drawing))
        XCTAssertEqual(lines.count, 4)

        let snapshot = try PageSnapshotter.make(drawing: drawing, canvasSize: CGSize(width: 1180, height: 820), lines: lines)
        XCTAssertGreaterThan(snapshot.region.maxY, 1500, "the low ink is inside the picture")
        XCTAssertLessThanOrEqual(max(snapshot.pixelWidth, snapshot.pixelHeight), 1024)
        XCTAssertLessThanOrEqual(snapshot.png.count, PageSnapshotter.maxBytes)
        XCTAssertTrue(lines.allSatisfy { snapshot.shows($0) }, "nothing slid out of a page this size")

        let low = try XCTUnwrap(lines.last)
        let wire = LineWire(low, scale: snapshot.scale, regionTop: snapshot.region.minY)
        XCTAssertEqual(wire.box.y, Double((low.box.minY - snapshot.region.minY) * snapshot.scale), accuracy: 0.001)
        XCTAssertLessThan(wire.box.y + wire.box.h, Double(snapshot.pixelHeight), "the box is inside the image the server gets")
    }

    func testWindowThatSlidesDropsLinesAboveItAndMeasuresFromItsTop() throws {
        let top = LineGrouper().group(TutorSession.inkStrokes(from: PKDrawing(strokes: [penStroke(x: 100, y: 100)])))[0]
        let bottomStroke = penStroke(x: 100, y: 4000)
        let drawing = PKDrawing(strokes: [penStroke(x: 100, y: 100), bottomStroke])
        let lines = LineGrouper().group(TutorSession.inkStrokes(from: drawing))
        let snapshot = try PageSnapshotter.make(drawing: drawing, canvasSize: CGSize(width: 1180, height: 820), lines: lines)
        XCTAssertGreaterThan(snapshot.region.minY, 0)
        XCTAssertFalse(snapshot.shows(top), "work far above the window is not in the picture, so its line is not sent")
        XCTAssertTrue(snapshot.shows(lines[1]))
        let wire = LineWire(lines[1], scale: snapshot.scale, regionTop: snapshot.region.minY)
        XCTAssertGreaterThan(wire.box.y, 0)
        XCTAssertLessThan(wire.box.y, Double(snapshot.pixelHeight))
    }

    func testPageIsInkPlusOneScreenAndNeverShorterThanTheScreen() {
        XCTAssertEqual(PageGeometry.contentHeight(viewportHeight: 820, inkBottom: nil), 820)
        XCTAssertEqual(PageGeometry.contentHeight(viewportHeight: 820, inkBottom: 300), 1120)
        XCTAssertEqual(PageGeometry.contentHeight(viewportHeight: 820, inkBottom: 790.2), 1611, "rounded up to whole points")
        XCTAssertEqual(PageGeometry.contentHeight(viewportHeight: 820, inkBottom: -50), 820, "never shorter than the screen")
        XCTAssertEqual(PageGeometry.contentHeight(viewportHeight: 820, inkBottom: .infinity), 820, "a bad bound cannot blow the page up")
    }

    func testScrollOffsetIsKeptInsideThePage() {
        XCTAssertEqual(PageGeometry.maxOffsetY(contentHeight: 1620, viewportHeight: 820), 800)
        XCTAssertEqual(PageGeometry.maxOffsetY(contentHeight: 820, viewportHeight: 820), 0)
        XCTAssertEqual(PageGeometry.clampedOffsetY(2000, contentHeight: 1620, viewportHeight: 820), 800, "page shrank under the screen")
        XCTAssertEqual(PageGeometry.clampedOffsetY(-40, contentHeight: 1620, viewportHeight: 820), 0)
    }

    func testMarkBelowTheScreenScrollsIntoViewAndAVisibleOneStaysPut() throws {
        let onScreen = CGRect(x: 100, y: 300, width: 500, height: 40)
        XCTAssertNil(PageGeometry.offsetToReveal(box: onScreen, currentOffsetY: 0, viewportHeight: 820, contentHeight: 1620))

        let below = CGRect(x: 100, y: 1200, width: 500, height: 40)
        let target = PageGeometry.offsetToReveal(box: below, currentOffsetY: 0, viewportHeight: 820, contentHeight: 2400)
        XCTAssertEqual(try XCTUnwrap(target), 1220 - 820 * 0.35, accuracy: 0.001, "the mark lands about a third of the way down")

        let scrolledPast = PageGeometry.offsetToReveal(box: onScreen, currentOffsetY: 700, viewportHeight: 820, contentHeight: 1620)
        XCTAssertEqual(try XCTUnwrap(scrolledPast), 320 - 820 * 0.35, accuracy: 0.001, "scrolls back up to a mark above the screen")

        // Too close to the bottom edge for its callout: scrolls so the callout has room.
        let edge = CGRect(x: 100, y: 760, width: 500, height: 40)
        XCTAssertNotNil(PageGeometry.offsetToReveal(box: edge, currentOffsetY: 0, viewportHeight: 820, contentHeight: 1620))

        // Clamped to the end of the page, and no pointless scroll when it is already as far as it can go.
        let last = CGRect(x: 100, y: 1560, width: 500, height: 40)
        XCTAssertEqual(try XCTUnwrap(PageGeometry.offsetToReveal(box: last, currentOffsetY: 0, viewportHeight: 820, contentHeight: 1620)), 800)
        XCTAssertNil(PageGeometry.offsetToReveal(box: last, currentOffsetY: 800, viewportHeight: 820, contentHeight: 1620))
    }

    func testSessionLogWritesOneJSONObjectPerLineAndNoSecrets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("log-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = SessionLog(directory: directory)
        log.record("decision", ["action": "wait", "latency_ms": 5200])
        log.record("error", ["where": "watch", "detail": "timed_out"])

        let exported = try XCTUnwrap(log.exportURL())
        let text = try String(contentsOf: exported, encoding: .utf8)
        let rows = text.split(separator: "\n")
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any])
            XCTAssertNotNil(object["t"])
            XCTAssertNotNil(object["type"])
        }
        XCTAssertFalse(text.lowercased().contains("bearer"))
    }

    /// Debug-only page capture: the picture lands next to the session log with the look id in its name, the log names the
    /// file and its size only, and the share-sheet export never carries the picture. (Tests build Debug, where `logsWords`
    /// is true; in Release it is false and `savePageImage` writes nothing.)
    func testDebugBuildKeepsPagePictureNextToTheLogWithTheLookID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("page-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = SessionLog(directory: directory)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])

        let name = try XCTUnwrap(log.savePageImage(png, kind: "watch", lookID: "w3-r17"))
        XCTAssertTrue(name.hasPrefix("page-"))
        XCTAssertTrue(name.hasSuffix("-watch-w3-r17.png"))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), png)

        let exported = try XCTUnwrap(log.exportURL())
        let text = try String(contentsOf: exported, encoding: .utf8)
        XCTAssertTrue(text.contains("\"page_saved\""))
        XCTAssertTrue(text.contains("\"bytes\":7"))
        XCTAssertFalse(text.contains("PNG"), "no picture bytes in the log")
    }
}
