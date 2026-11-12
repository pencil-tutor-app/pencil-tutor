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
}
