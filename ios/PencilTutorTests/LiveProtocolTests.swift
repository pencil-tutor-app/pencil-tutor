import XCTest
@testable import PencilTutor

/// The data-channel JSON. The server-event samples are shaped like the ones the deployed GPT-Live API sent on 2026-11-13
/// (session.started and session.closed also carry the full session snapshot, trimmed here).
final class LiveProtocolTests: XCTestCase {
    func testDecodesSessionStartedWithItsId() {
        let json = #"{"event_id":"e1","type":"session.started","session":{"id":"live_u1_abc","model":"gpt-live-1","expires_at":1794593476}}"#
        XCTAssertEqual(LiveServerEvent.decode(json), .started(sessionID: "live_u1_abc"))
    }

    func testDecodesTranscriptFragmentsKeepingSpaces() {
        let student = #"{"type":"session.input_transcript.delta","start_ms":1000,"end_ms":1200,"delta":" can you","event_id":"e2"}"#
        let tutor = #"{"type":"session.output_transcript.delta","start_ms":400,"end_ms":600,"delta":"Hey,","event_id":"e3"}"#
        XCTAssertEqual(LiveServerEvent.decode(student), .inputTranscript(" can you"))
        XCTAssertEqual(LiveServerEvent.decode(tutor), .outputTranscript("Hey,"))
    }

    func testDecodesAClientDelegation() {
        let json = #"{"type":"session.delegation.created","event_id":"e4","offset_ms":1000,"delegation":{"id":"item_9tA2bF3h7K9m2P5q8R1s4","type":"delegation","target":"client"}}"#
        XCTAssertEqual(LiveServerEvent.decode(json), .delegationCreated(id: "item_9tA2bF3h7K9m2P5q8R1s4", target: "client"))
    }

    func testADelegationWithoutAnIdIsNotActedOn() {
        let json = #"{"type":"session.delegation.created","delegation":{"type":"delegation"}}"#
        XCTAssertEqual(LiveServerEvent.decode(json), .other(type: "session.delegation.created"))
    }

    func testDecodesUsageAndClose() {
        XCTAssertEqual(LiveServerEvent.decode(#"{"type":"session.usage.updated","usage":{"seconds":15.0},"context_window":{"usage_ratio":0.017}}"#), .usage(seconds: 15))
        XCTAssertEqual(
            LiveServerEvent.decode(#"{"type":"session.closed","reason":"close_requested","usage":{"seconds":22.0},"session":{"id":"live_1"}}"#),
            .closed(reason: "close_requested", seconds: 22)
        )
    }

    func testDecodesAcknowledgementsWithTheirClientEventId() {
        XCTAssertEqual(LiveServerEvent.decode(#"{"type":"session.input_audio.muted","client_event_id":"mute_1","event_id":"e"}"#), .muted(clientEventID: "mute_1"))
        XCTAssertEqual(LiveServerEvent.decode(#"{"type":"session.input_audio.unmuted","client_event_id":"u_1"}"#), .unmuted(clientEventID: "u_1"))
        XCTAssertEqual(LiveServerEvent.decode(#"{"type":"session.thinking.appended","client_event_id":"app_2","start_ms":600,"end_ms":800}"#), .appended(kind: "thinking", clientEventID: "app_2"))
        XCTAssertEqual(LiveServerEvent.decode(#"{"type":"session.commentary.appended","client_event_id":"app_3"}"#), .appended(kind: "commentary", clientEventID: "app_3"))
    }

    func testDecodesAnErrorWithItsCodeAndTheCommandItBelongsTo() {
        let json = #"{"type":"error","event_id":"e","error":{"type":"server_error","code":"context_injection_incomplete","message":"The session closed before the estimated context injection completed.","param":null,"client_event_id":"probe_1"}}"#
        XCTAssertEqual(
            LiveServerEvent.decode(json),
            .failure(type: "server_error", code: "context_injection_incomplete",
                     message: "The session closed before the estimated context injection completed.", clientEventID: "probe_1")
        )
    }

    func testUnknownTypesStillComeThroughByName() {
        XCTAssertEqual(LiveServerEvent.decode(#"{"type":"session.notice","detail":"x"}"#), .other(type: "session.notice"))
    }

    func testNonJsonAndTypelessJsonDecodeToNil() {
        XCTAssertNil(LiveServerEvent.decode("hello"))
        XCTAssertNil(LiveServerEvent.decode(#"{"delta":"x"}"#))
        XCTAssertNil(LiveServerEvent.decode(#"["type"]"#))
    }

    // MARK: - What the app sends

    private func object(_ event: LiveClientEvent) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(event.json().utf8)) as? [String: Any])
    }

    func testCommentaryForADelegationCarriesItsId() throws {
        let sent = try object(.commentary(eventID: "app_1", delegationID: "item_1", text: "Line two is wrong."))
        XCTAssertEqual(sent["type"] as? String, "session.commentary.append")
        XCTAssertEqual(sent["event_id"] as? String, "app_1")
        XCTAssertEqual(sent["delegation_id"] as? String, "item_1")
        XCTAssertEqual(sent["content"] as? String, "Line two is wrong.")
    }

    func testSessionWideCommentaryAndThinkingSendAnExplicitNullDelegationId() throws {
        for event in [LiveClientEvent.commentary(eventID: "a", delegationID: nil, text: "hint"), .thinking(eventID: "b", text: "fact")] {
            let sent = try object(event)
            XCTAssertTrue(sent["delegation_id"] is NSNull, "the API requires delegation_id; null means session wide")
        }
        XCTAssertEqual(try object(.thinking(eventID: "b", text: "fact"))["type"] as? String, "session.thinking.append")
    }

    func testMuteUnmuteAndCloseHaveNoPayload() throws {
        XCTAssertEqual(try object(.mute(eventID: "m"))["type"] as? String, "session.input_audio.mute")
        XCTAssertEqual(try object(.unmute(eventID: "u"))["type"] as? String, "session.input_audio.unmute")
        let close = try object(.close(eventID: "c"))
        XCTAssertEqual(close["type"] as? String, "session.close")
        XCTAssertNil(close["content"])
        XCTAssertNil(close["delegation_id"])
    }

    func testLongTextIsClippedUnderTheFiveHundredTokenLimit() throws {
        let sent = try object(.thinking(eventID: "b", text: String(repeating: "x", count: 5_000)))
        XCTAssertEqual((sent["content"] as? String)?.count, LiveClientEvent.maxTextCharacters)
    }

    /// The server lets exactly these five through (server/lib/live.ts ALLOWED_CLIENT_EVENTS). A new client event type
    /// added here without the server allow-list would be refused by OpenAI.
    func testTheAppOnlyEverSendsTheFiveAllowListedEventTypes() {
        let events: [LiveClientEvent] = [
            .thinking(eventID: "1", text: "t"),
            .commentary(eventID: "2", delegationID: nil, text: "t"),
            .mute(eventID: "3"), .unmute(eventID: "4"), .close(eventID: "5")
        ]
        let types = Set(events.map(\.eventType))
        XCTAssertEqual(types, [
            "session.thinking.append", "session.commentary.append", "session.input_audio.mute",
            "session.input_audio.unmute", "session.close"
        ])
    }

    // MARK: - Context wording

    func testVerdictForACleanLookSaysNoProblem() {
        let text = LiveContext.verdict(lineCount: 3, flaggedLine: nil, hintWritten: nil)
        XCTAssertTrue(text.contains("3 lines"))
        XCTAssertTrue(text.contains("saw no problem"))
    }

    func testVerdictForAFlaggedLineNamesTheLineAndTheNote() {
        let text = LiveContext.verdict(lineCount: 1, flaggedLine: 2, hintWritten: "Check the signs here")
        XCTAssertTrue(text.contains("1 line"))
        XCTAssertTrue(text.contains("line 2"))
        XCTAssertTrue(text.contains("Check the signs here"))
    }
}
