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

    // MARK: - The endless page (every direction, zoom) and the tool rail

    /// A short horizontal-ish pen stroke whose left end is at (x, y), for building pages in tests.
    private func penStroke(x: CGFloat, y: CGFloat, created: Date = Date()) -> PKStroke {
        var points: [PKStrokePoint] = []
        for step in 0..<12 {
            points.append(PKStrokePoint(location: CGPoint(x: x + CGFloat(step) * 20, y: y + CGFloat(step % 3) * 6),
                                        timeOffset: Double(step) * 0.01, size: CGSize(width: 4, height: 4),
                                        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: created))
    }

    private let screen = CGSize(width: 1180, height: 820)
    private var home: CGRect { PageGeometry.homeRect(viewport: screen) }

    func testInkOnTheFirstScreenGetsTheSamePictureAsBefore() {
        let box = CGRect(x: home.minX + 100, y: home.minY + 100, width: 600, height: 40)
        let region = PageSnapshotter.region(canvasSize: screen, inkBox: box)
        XCTAssertEqual(region.rect, home)
        XCTAssertEqual(region.scale, 1024 / 1180, accuracy: 0.0001, "the old rule: longer side of the screen at 1024 px")
        let empty = PageSnapshotter.region(canvasSize: screen, inkBox: nil)
        XCTAssertEqual(empty.rect, home)
        // Ink 10 pt from the bottom edge still fits: its 40 pt margin is blank paper, not a reason to grow the picture.
        let nearEdge = CGRect(x: home.minX + 100, y: home.maxY - 80, width: 600, height: 40)
        XCTAssertEqual(PageSnapshotter.region(canvasSize: screen, inkBox: nearEdge).rect.height, 820)
    }

    func testPictureGrowsDownFromTheFirstScreenAndShrinksToStayWithin1024Pixels() {
        let box = CGRect(x: home.minX + 100, y: home.minY + 100, width: 600, height: 1400)   // ink down to 1500 below the top
        let region = PageSnapshotter.region(canvasSize: screen, inkBox: box)
        XCTAssertEqual(region.rect.minY, home.minY, "the first screen stays in the picture, as before")
        XCTAssertEqual(region.rect.maxY, home.minY + 1540, accuracy: 0.001, "lowest ink plus the 40 pt margin")
        XCTAssertEqual(region.scale, 1024 / 1540, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(region.rect.height * region.scale, 1024.001)
        XCTAssertLessThanOrEqual(region.rect.width * region.scale, 1024.001)
    }

    func testInkLeftOfAndAboveTheFirstScreenIsInThePicture() {
        // Written in the reserve to the upper left of the first screen: nothing of the first screen is in the picture.
        let box = CGRect(x: home.minX - 900, y: home.minY - 700, width: 500, height: 60)
        let region = PageSnapshotter.region(canvasSize: screen, inkBox: box)
        XCTAssertTrue(region.rect.contains(box), "all the ink is in the picture")
        XCTAssertFalse(region.rect.intersects(home), "and the empty first screen is not wasted on it")
        XCTAssertGreaterThanOrEqual(region.rect.width, 1180, "at least one screen wide")
        XCTAssertGreaterThanOrEqual(region.rect.height, 820)
        XCTAssertEqual(region.scale, 1024 / 1180, accuracy: 0.0001)
    }

    func testInkSpreadOverTwoDirectionsKeepsTheLegibleScaleAndFollowsTheNewestLine() {
        // 3000 pt wide and 2600 tall: far over what 1024 px can hold at the legible scale.
        let box = CGRect(x: home.minX, y: home.minY, width: 3000, height: 2600)
        let newest = CGRect(x: home.minX + 2500, y: home.minY + 2200, width: 400, height: 40)
        let region = PageSnapshotter.region(canvasSize: screen, inkBox: box, newestBox: newest)
        XCTAssertEqual(region.scale, PageSnapshotter.minLegibleScale, accuracy: 0.0001)
        XCTAssertEqual(region.rect.width, 1024 / PageSnapshotter.minLegibleScale, accuracy: 0.01)
        XCTAssertEqual(region.rect.height, 1024 / PageSnapshotter.minLegibleScale, accuracy: 0.01)
        XCTAssertTrue(region.rect.contains(newest), "the newest work is in the window")
        XCTAssertEqual(region.rect.maxX, newest.maxX + 40, accuracy: 0.01, "the window ends just past the newest line, as it did downwards")
        XCTAssertEqual(region.rect.maxY, newest.maxY + 40, accuracy: 0.01)
        XCTAssertLessThanOrEqual(max(region.rect.width, region.rect.height) * region.scale, 1024.001)
    }

    func testWindowOnlySlidesInTheDirectionThatIsTooBig() {
        // Tall but narrow: the width is the whole ink, only the height slides.
        let box = CGRect(x: home.minX, y: home.minY, width: 700, height: 4000)
        let newest = CGRect(x: home.minX + 100, y: home.minY + 3900, width: 400, height: 40)
        let region = PageSnapshotter.region(canvasSize: screen, inkBox: box, newestBox: newest)
        XCTAssertEqual(region.rect.maxY, newest.maxY + 40, accuracy: 0.01)
        XCTAssertEqual(region.rect.height, 1024 / PageSnapshotter.minLegibleScale, accuracy: 0.01)
        XCTAssertLessThan(region.rect.width, region.rect.height)
        XCTAssertTrue(region.rect.contains(newest))
    }

    func testSnapshotOfInkFarFromTheOriginMeasuresLineBoxesFromThePictureCorner() throws {
        // Two lines side by side far to the right and below the first screen, as a student who panned would write them.
        let x = home.minX + 2600, y = home.minY + 1800
        let drawing = PKDrawing(strokes: [penStroke(x: x, y: y), penStroke(x: x, y: y + 60)])
        let lines = LineGrouper().group(TutorSession.inkStrokes(from: drawing))
        XCTAssertEqual(lines.count, 2)

        let snapshot = try PageSnapshotter.make(drawing: drawing, canvasSize: screen, lines: lines)
        XCTAssertLessThanOrEqual(max(snapshot.pixelWidth, snapshot.pixelHeight), 1024)
        XCTAssertLessThanOrEqual(snapshot.png.count, PageSnapshotter.maxBytes)
        XCTAssertTrue(lines.allSatisfy { snapshot.shows($0) })
        XCTAssertGreaterThan(snapshot.region.minX, home.minX, "the empty first screen is not in this picture")

        let wire = LineWire(lines[1], scale: snapshot.scale, regionOrigin: snapshot.region.origin)
        XCTAssertEqual(wire.box.x, Double((lines[1].box.minX - snapshot.region.minX) * snapshot.scale), accuracy: 0.001)
        XCTAssertEqual(wire.box.y, Double((lines[1].box.minY - snapshot.region.minY) * snapshot.scale), accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(wire.box.x, 0)
        XCTAssertLessThan(wire.box.x + wire.box.w, Double(snapshot.pixelWidth), "the box is inside the image the server gets")
        XCTAssertLessThan(wire.box.y + wire.box.h, Double(snapshot.pixelHeight))
    }

    func testWindowThatSlidesDropsLinesOutsideItInBothDirections() throws {
        let far = penStroke(x: home.minX + 4200, y: home.minY + 3600, created: Date(timeIntervalSince1970: 2_000))
        let drawing = PKDrawing(strokes: [penStroke(x: home.minX + 100, y: home.minY + 100, created: Date(timeIntervalSince1970: 1_000)), far])
        let lines = LineGrouper().group(TutorSession.inkStrokes(from: drawing))
        let snapshot = try PageSnapshotter.make(drawing: drawing, canvasSize: screen, lines: lines)
        XCTAssertFalse(snapshot.shows(lines[0]), "work far up and left of the window is not in the picture, so its line is not sent")
        XCTAssertTrue(snapshot.shows(lines[1]))
        let wire = LineWire(lines[1], scale: snapshot.scale, regionOrigin: snapshot.region.origin)
        XCTAssertGreaterThan(wire.box.x, 0)
        XCTAssertGreaterThan(wire.box.y, 0)
        XCTAssertLessThan(wire.box.y, Double(snapshot.pixelHeight))
    }

    // MARK: Page size, re-anchor, zoom

    func testPageIsFirstScreenAndInkPlusOneScreenInEveryDirection() {
        let reserve = PageGeometry.homeReserve
        XCTAssertEqual(PageGeometry.contentSize(viewport: screen, ink: nil), CGSize(width: reserve + 2 * 1180, height: reserve + 2 * 820))
        let right = CGRect(x: reserve + 5000, y: reserve + 100, width: 300, height: 40)
        XCTAssertEqual(PageGeometry.contentSize(viewport: screen, ink: right).width, reserve + 5300 + 1180, "grows to the right")
        let down = CGRect(x: reserve + 100, y: reserve + 4000, width: 300, height: 40)
        XCTAssertEqual(PageGeometry.contentSize(viewport: screen, ink: down).height, reserve + 4040 + 820, "grows downwards")
        let left = CGRect(x: 2000, y: 2000, width: 300, height: 40)   // left of and above the first screen
        XCTAssertEqual(PageGeometry.contentSize(viewport: screen, ink: left), PageGeometry.contentSize(viewport: screen, ink: nil),
                       "the reserve already covers it; the page does not grow")
        XCTAssertEqual(PageGeometry.contentSize(viewport: screen, ink: CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1)),
                       PageGeometry.contentSize(viewport: screen, ink: nil), "a bad bound cannot blow the page up")
        let rounded = CGRect(x: reserve, y: reserve, width: 790.2, height: 40)
        XCTAssertEqual(PageGeometry.contentSize(viewport: screen, ink: rounded).width, reserve + 2 * 1180, "inside the first screen")
        XCTAssertEqual(PageGeometry.contentSize(viewport: CGSize(width: 1180.5, height: 820.2), ink: nil).width, ceil(reserve + 2 * 1180.5))
    }

    func testReanchorOnlyWhenInkComesCloseToTheLeftOrTopEdge() throws {
        let reserve = PageGeometry.homeReserve
        XCTAssertNil(PageGeometry.reanchorShift(viewport: screen, ink: nil))
        XCTAssertNil(PageGeometry.reanchorShift(viewport: screen, ink: CGRect(x: reserve, y: reserve, width: 500, height: 40)))
        XCTAssertNil(PageGeometry.reanchorShift(viewport: screen, ink: CGRect(x: 1500, y: 1500, width: 500, height: 40)),
                     "a screen of blank paper is still left of and above it")
        let shift = try XCTUnwrap(PageGeometry.reanchorShift(viewport: screen, ink: CGRect(x: 500, y: 2500, width: 500, height: 40)))
        XCTAssertEqual(shift.width, 2500, "ink minX 500 goes back to the reserve (3000), rounded up to 100")
        XCTAssertEqual(shift.height, 0)
        let corner = try XCTUnwrap(PageGeometry.reanchorShift(viewport: screen, ink: CGRect(x: 10, y: 33, width: 5, height: 5)))
        XCTAssertEqual(corner.width, 3000)
        XCTAssertEqual(corner.height, 3000)
        // After the shift the ink has a full reserve of blank page again.
        let after = CGRect(x: 500 + shift.width, y: 2500, width: 500, height: 40)
        XCTAssertNil(PageGeometry.reanchorShift(viewport: screen, ink: after))
        XCTAssertNil(PageGeometry.reanchorShift(viewport: screen, ink: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)))
    }

    func testMarkMovesWithAReanchorAndKeepsItsInkSignatureInStep() {
        let strokes = [InkStroke(id: 0, bounds: CGRect(x: 120.4, y: 80.9, width: 300.2, height: 40.7), createdAt: Date())]
        let box = CGRect(x: 100, y: 60, width: 400, height: 90)
        let mark = Mark(lineIndex: 2, box: box, hint: "h", inkSignature: Mark.inkSignature(in: box, strokes: strokes))
        let moved = mark.moved(by: CGSize(width: 200, height: 300))
        XCTAssertEqual(moved.box, box.offsetBy(dx: 200, dy: 300))
        let shiftedStrokes = [InkStroke(id: 0, bounds: strokes[0].bounds.offsetBy(dx: 200, dy: 300), createdAt: Date())]
        XCTAssertEqual(moved.inkSignature, Mark.inkSignature(in: moved.box, strokes: shiftedStrokes),
                       "untouched ink still looks untouched after the move")
    }

    func testVisibleRectAndOffsetClampFollowTheZoom() {
        XCTAssertEqual(PageGeometry.visibleRect(offset: CGPoint(x: 400, y: 200), viewport: screen, zoom: 2),
                       CGRect(x: 200, y: 100, width: 590, height: 410))
        XCTAssertEqual(PageGeometry.visibleRect(offset: .zero, viewport: screen, zoom: 0.5).width, 2360)
        let content = CGSize(width: 5000, height: 4000)
        XCTAssertEqual(PageGeometry.clampedOffset(CGPoint(x: 9000, y: -40), contentSize: content, viewport: screen), CGPoint(x: 3820, y: 0))
        XCTAssertEqual(PageGeometry.clampedOffset(CGPoint(x: 100, y: 100), contentSize: CGSize(width: 900, height: 600), viewport: screen),
                       .zero, "a page smaller than the screen (zoomed out) does not scroll")
    }

    func testMarkScrollsIntoViewInBothDirectionsAndAVisibleOneStaysPut() throws {
        let content = CGSize(width: 9000, height: 8000)
        let onScreen = CGRect(x: 600, y: 300, width: 500, height: 40)
        XCTAssertNil(PageGeometry.offsetToReveal(box: onScreen, offset: .zero, zoom: 1, viewport: screen, contentSize: content))

        let below = CGRect(x: 600, y: 1200, width: 500, height: 40)
        let down = try XCTUnwrap(PageGeometry.offsetToReveal(box: below, offset: .zero, zoom: 1, viewport: screen, contentSize: content))
        XCTAssertEqual(down.y, 1220 - 820 * 0.35, accuracy: 0.001, "the mark lands about a third of the way down")
        XCTAssertEqual(down.x, 0, "already in view sideways: no sideways scroll")

        let rightOfScreen = CGRect(x: 4000, y: 300, width: 500, height: 40)
        let right = try XCTUnwrap(PageGeometry.offsetToReveal(box: rightOfScreen, offset: .zero, zoom: 1, viewport: screen, contentSize: content))
        XCTAssertEqual(right.x, 4250 - 590, accuracy: 0.001, "centred sideways")
        XCTAssertEqual(right.y, 0, "already in view up and down: no vertical jump")

        let scrolledPast = try XCTUnwrap(PageGeometry.offsetToReveal(box: onScreen, offset: CGPoint(x: 3000, y: 700), zoom: 1,
                                                                     viewport: screen, contentSize: content))
        XCTAssertEqual(scrolledPast.y, 320 - 820 * 0.35, accuracy: 0.001, "scrolls back up and left to a mark off the top left")
        XCTAssertEqual(scrolledPast.x, 850 - 590, accuracy: 0.001)

        // Too close to the bottom edge for its callout: scrolls so the callout has room.
        XCTAssertNotNil(PageGeometry.offsetToReveal(box: CGRect(x: 600, y: 760, width: 500, height: 40), offset: .zero, zoom: 1,
                                                    viewport: screen, contentSize: content))

        // Clamped to the end of the page, and no pointless scroll when it is already as far as it can go.
        let tight = CGSize(width: 1180, height: 1620)
        let last = CGRect(x: 100, y: 1560, width: 500, height: 40)
        XCTAssertEqual(try XCTUnwrap(PageGeometry.offsetToReveal(box: last, offset: .zero, zoom: 1, viewport: screen, contentSize: tight)).y, 800)
        XCTAssertNil(PageGeometry.offsetToReveal(box: last, offset: CGPoint(x: 0, y: 800), zoom: 1, viewport: screen, contentSize: tight))
    }

    // MARK: - The floating problem card (2026-11-15: a long prompt's card covered the first line of work)

    func testHomeSitsBelowTheCardSoTheFirstLineStartsClearOfIt() {
        // The page's origin (where the first stroke goes) appears `clearance` points below the top of the screen.
        let offset = PageGeometry.homeOffset(zoom: 1, topClearance: 214)
        XCTAssertEqual(offset, CGPoint(x: PageGeometry.homeReserve, y: PageGeometry.homeReserve - 214))
        XCTAssertEqual(PageGeometry.homeReserve - offset.y, 214, "origin is 214 pt down the screen")
        XCTAssertEqual(PageGeometry.homeOffset(zoom: 1, topClearance: 0), CGPoint(x: PageGeometry.homeReserve, y: PageGeometry.homeReserve),
                       "no card, no change from before")
        XCTAssertEqual(PageGeometry.homeOffset(zoom: 1, topClearance: -30).y, PageGeometry.homeReserve, "a bad measurement is ignored")
        // Zoomed, the origin is still `clearance` screen points down.
        let zoomed = PageGeometry.homeOffset(zoom: 2, topClearance: 100)
        XCTAssertEqual(PageGeometry.homeReserve * 2 - zoomed.y, 100)
    }

    func testAMarkUnderTheCardIsScrolledClearOfIt() throws {
        let content = CGSize(width: 9000, height: 8000)
        // The page is at the top; the mark sits 90 pt down the screen, where a 214 pt card would cover it.
        let offset = CGPoint(x: 0, y: 3000)
        let hidden = CGRect(x: 120, y: 3090, width: 300, height: 40)
        XCTAssertNil(PageGeometry.offsetToReveal(box: hidden, offset: offset, zoom: 1, viewport: screen, contentSize: content),
                     "without a card it is in view (it clears the 80 pt callout allowance)")
        let moved = try XCTUnwrap(PageGeometry.offsetToReveal(box: hidden, offset: offset, zoom: 1, viewport: screen,
                                                              contentSize: content, topClearance: 214))
        let screenTop = hidden.minY - moved.y
        XCTAssertGreaterThanOrEqual(screenTop, 214 + PageGeometry.cardMargin, "the top of the mark ends up below the card")
    }

    func testAMarkBelowTheCardStaysPut() {
        let content = CGSize(width: 9000, height: 8000)
        let offset = CGPoint(x: 0, y: 3000)
        let clear = CGRect(x: 120, y: 3000 + 400, width: 300, height: 40)
        XCTAssertNil(PageGeometry.offsetToReveal(box: clear, offset: offset, zoom: 1, viewport: screen, contentSize: content, topClearance: 214))
    }

    func testTheClearanceCountsInScreenPointsAtAnyZoom() throws {
        let content = CGSize(width: 12000, height: 10000)
        // At 2x the mark's top is 60 pt down the screen: under a 214 pt card, so it must move down to at least 226 pt.
        let offset = CGPoint(x: 5800, y: 5800)
        let box = CGRect(x: 3000, y: 2930, width: 200, height: 20)      // screen y = 2930*2 - 5800 = 60
        let moved = try XCTUnwrap(PageGeometry.offsetToReveal(box: box, offset: offset, zoom: 2, viewport: screen,
                                                              contentSize: content, topClearance: 214))
        XCTAssertGreaterThanOrEqual(box.minY * 2 - moved.y, 214 + PageGeometry.cardMargin - 0.001)
    }

    func testRevealRespectsTheZoom() throws {
        // At 2x, page point (3100, 3050) is on screen at (6200 - offset.x, 6100 - offset.y).
        let content = CGSize(width: 12000, height: 10000)   // zoomed size
        let box = CGRect(x: 3000, y: 3000, width: 200, height: 50)
        let visibleAt2x = CGPoint(x: 5800, y: 5800)   // shows page x 2900...3490, y 2900...3310
        XCTAssertNil(PageGeometry.offsetToReveal(box: box, offset: visibleAt2x, zoom: 2, viewport: screen, contentSize: content))
        let moved = try XCTUnwrap(PageGeometry.offsetToReveal(box: box, offset: .zero, zoom: 2, viewport: screen, contentSize: content))
        XCTAssertEqual(moved.x, 3100 * 2 - 590, accuracy: 0.001)
        XCTAssertEqual(moved.y, 3025 * 2 - 820 * 0.35, accuracy: 0.001)
        // Zoomed out to 0.5x the same mark is a small thing in a big view: it is in view without any scroll.
        XCTAssertNil(PageGeometry.offsetToReveal(box: box, offset: CGPoint(x: 1000, y: 1000), zoom: 0.5, viewport: screen,
                                                 contentSize: CGSize(width: 6000, height: 5000)))
    }

    // MARK: Line grouping on a big plane

    func testLineGroupingDoesNotCareWhereOnThePlaneTheInkIs() {
        func lines(offsetX: CGFloat, offsetY: CGFloat) -> [InkLine] {
            var strokes: [PKStroke] = []
            for row in 0..<3 { strokes.append(penStroke(x: 100 + offsetX, y: 200 + CGFloat(row) * 60 + offsetY)) }
            return LineGrouper().group(TutorSession.inkStrokes(from: PKDrawing(strokes: strokes)))
        }
        let nearOrigin = lines(offsetX: 0, offsetY: 0)
        let farAway = lines(offsetX: 6000, offsetY: 5000)
        XCTAssertEqual(nearOrigin.count, 3)
        XCTAssertEqual(farAway.count, 3)
        XCTAssertEqual(farAway.map(\.isSideCalculation), nearOrigin.map(\.isSideCalculation))
        for (near, far) in zip(nearOrigin, farAway) {
            XCTAssertEqual(far.box.minX - near.box.minX, 6000, accuracy: 0.5)
            XCTAssertEqual(far.box.minY - near.box.minY, 5000, accuracy: 0.5)
        }
    }

    func testTwoBlocksFarApartAtTheSameHeightAreTwoLinesNotOne() {
        let drawing = PKDrawing(strokes: [penStroke(x: 3100, y: 3100), penStroke(x: 7000, y: 3105)])
        let lines = LineGrouper().group(TutorSession.inkStrokes(from: drawing))
        XCTAssertEqual(lines.count, 2, "the 160 pt side gap splits them; each keeps its own box")
        XCTAssertLessThan(lines[0].box.maxX, lines[1].box.minX)
    }

    // MARK: Pencil rules, finger-tap gestures and the tool rail

    func testPencilDoubleTapSwitchesToTheEraserAndBack() {
        XCTAssertEqual(PencilRules.outcome(for: .switchEraser, current: .pen, previous: .pen), .select(.eraser))
        XCTAssertEqual(PencilRules.outcome(for: .switchEraser, current: .eraser, previous: .marker), .select(.marker))
        XCTAssertEqual(PencilRules.outcome(for: .switchEraser, current: .eraser, previous: .eraser), .select(.pen), "never stuck on the eraser")
        XCTAssertEqual(PencilRules.outcome(for: .switchPrevious, current: .lasso, previous: .pen), .select(.pen))
        XCTAssertEqual(PencilRules.outcome(for: .switchPrevious, current: .pen, previous: .pen), .nothing)
        XCTAssertEqual(PencilRules.outcome(for: .openPalette, current: .pen, previous: .pen), .railAlwaysVisible, "the rail is already up")
        XCTAssertEqual(PencilRules.outcome(for: .ignore, current: .pen, previous: .pen), .nothing)
        XCTAssertEqual(PencilRules.outcome(for: .system, current: .pen, previous: .pen), .nothing)
    }

    func testTwoFingerTapIsUndoThreeFingerTapIsRedoAndOnlyFingersCount() {
        XCTAssertEqual(RailGestureRules.gesture(forTapWith: 2, usingFingers: true), .undo)
        XCTAssertEqual(RailGestureRules.gesture(forTapWith: 3, usingFingers: true), .redo)
        XCTAssertNil(RailGestureRules.gesture(forTapWith: 1, usingFingers: true), "one finger is just a touch of the page")
        XCTAssertNil(RailGestureRules.gesture(forTapWith: 4, usingFingers: true))
        XCTAssertNil(RailGestureRules.gesture(forTapWith: 2, usingFingers: false), "the Pencil never undoes")
        XCTAssertNil(RailGestureRules.gesture(forTapWith: 3, usingFingers: false))
    }

    func testChoosingAColourOrWidthWithTheEraserGoesBackToTheLastInkTool() {
        var style = ToolRailStyle()
        style.select(.marker)
        style.select(.eraser)
        style.choose(colour: .blue)
        XCTAssertEqual(style.tool, .marker)
        XCTAssertEqual(style.colour, .blue)
        style.select(.lasso)
        style.choose(width: .thick)
        XCTAssertEqual(style.tool, .marker)
        XCTAssertEqual(style.width, .thick)
        XCTAssertEqual(ToolRailStyle().summary, "Pen, black, medium")
        var eraser = ToolRailStyle()
        eraser.select(.eraser)
        XCTAssertEqual(eraser.summary, "Eraser")
    }

    func testSwatchesShowTheHighlighterColoursWhileTheHighlighterIsOn() {
        var style = ToolRailStyle()
        XCTAssertEqual(style.swatchColour(.black), UIColor.black)
        style.select(.marker)
        XCTAssertEqual(style.swatchColour(.black), InkColour.black.highlighterColor, "black shows yellow")
        XCTAssertNotEqual(style.swatchColour(.black), UIColor.black)
        XCTAssertEqual(style.swatchColour(.blue), InkColour.blue.uiColor)
    }

    func testEachRailToolMakesTheMatchingPencilKitTool() throws {
        var style = ToolRailStyle()
        let pen = try XCTUnwrap(style.pkTool() as? PKInkingTool)
        XCTAssertEqual(pen.inkType, .pen)
        XCTAssertEqual(pen.width, InkWidth.medium.penWidth, accuracy: 0.001)
        style.select(.marker)
        style.choose(width: .thick)
        let marker = try XCTUnwrap(style.pkTool() as? PKInkingTool)
        XCTAssertEqual(marker.inkType, .marker)
        XCTAssertNotEqual(InkColour.black.highlighterColor, UIColor.black, "a black highlighter is yellow")
        XCTAssertEqual(InkColour.blue.highlighterColor, InkColour.blue.uiColor, "other colours stay as they are")
        style.select(.eraser)
        XCTAssertTrue(style.pkTool() is PKEraserTool)
        style.select(.lasso)
        XCTAssertTrue(style.pkTool() is PKLassoTool)
    }

    @MainActor
    func testEveryRailChoiceSetsTheCanvasToolLogsLabelsOnlyAndNeverNeedsReopening() throws {
        let suite = "rail-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let canvas = PKCanvasView()
        var events: [(String, [String: Any])] = []
        let model = ToolRailModel(defaults: defaults)
        model.attach(canvas: canvas) { type, fields in events.append((type, fields)) }
        XCTAssertTrue(canvas.tool is PKInkingTool, "starts as the black pen")

        // Edward's case: eraser, then a colour. The colour takes the pen back and there is no second step.
        model.select(.eraser)
        XCTAssertTrue(canvas.tool is PKEraserTool)
        model.choose(colour: .red)
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .pen, "a colour while erasing returns to the pen")
        XCTAssertEqual(model.style.tool, .pen)
        XCTAssertEqual(model.style.colour, .red)
        model.choose(width: .thick)
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.width ?? 0, InkWidth.thick.penWidth, accuracy: 0.001)

        // The Pencil double-tap goes to the eraser and back to the red pen.
        model.pencilGesture(.doubleTap, preferred: .switchEraser)
        XCTAssertTrue(canvas.tool is PKEraserTool)
        model.pencilGesture(.doubleTap, preferred: .switchEraser)
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .pen)
        // "Show the palette" has nothing to show: it changes nothing and says so in the log.
        model.pencilGesture(.squeeze, preferred: .openPalette)
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .pen)
        let squeeze = try XCTUnwrap(events.last { $0.0 == "pencil_squeeze" }?.1)
        XCTAssertEqual(squeeze["result"] as? String, "rail_always_visible")

        let types = events.map(\.0)
        XCTAssertTrue(types.contains("tool_selected") && types.contains("pencil_double_tap"))
        XCTAssertFalse(types.contains { $0.hasPrefix("wheel_") }, "no wheel left to open or close")
        let selected = try XCTUnwrap(events.first { $0.0 == "tool_selected" }?.1)
        XCTAssertEqual(selected["tool"] as? String, "eraser")
        XCTAssertEqual(selected["source"] as? String, "rail")
        XCTAssertTrue(events.allSatisfy { JSONSerialization.isValidJSONObject($0.1) }, "plain labels and numbers only")

        // A new model (the next problem) starts with the same pen.
        let next = ToolRailModel(defaults: defaults)
        XCTAssertEqual(next.style.colour, .red)
        XCTAssertEqual(next.style.width, .thick)
    }

    @MainActor
    func testUndoRedoFromTheRailAndFromFingerTapsLogTheirResult() throws {
        let suite = "rail-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let canvas = PKCanvasView()
        var events: [(String, [String: Any])] = []
        let model = ToolRailModel(defaults: defaults)
        model.attach(canvas: canvas) { type, fields in events.append((type, fields)) }
        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(model.canRedo)

        model.undo()
        model.redo()
        model.fingerTap(.undo)
        model.fingerTap(.redo)

        XCTAssertEqual(events.map(\.0), ["rail_undo", "rail_redo", "gesture_undo", "gesture_redo"])
        // A blank page has nothing to undo; a canvas outside a window may have no undo manager at all.
        let expected = canvas.undoManager == nil ? "no_undo_manager" : "nothing"
        XCTAssertTrue(events.allSatisfy { $0.1["result"] as? String == expected }, "result was \(events.map { $0.1["result"] ?? "-" })")
        XCTAssertTrue(events.allSatisfy { JSONSerialization.isValidJSONObject($0.1) })
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
