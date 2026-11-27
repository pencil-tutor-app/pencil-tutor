import XCTest
@testable import PencilTutor

/// A stand-in for the WebRTC connection. It records what the app sends and lets a test play the session's side.
@MainActor
final class FakeLiveTransport: LiveTransport {
    var onMessage: ((String) -> Void)?
    var onClosed: ((String) -> Void)?

    var offer: Result<String, LiveFailure> = .success("v=0\r\nOFFER")
    var answerFailure: LiveFailure?
    /// Whether the session answers by sending `session.started` once the answer is applied.
    var startsSession = true
    /// Whether the session answers `session.close` with `session.closed`.
    var confirmsClose = true
    var channelOpen = true

    private(set) var appliedAnswer: String?
    private(set) var sent: [String] = []
    private(set) var micEnabled = true
    private(set) var closeCalls = 0

    func prepareOffer() async throws -> String { try offer.get() }

    func applyAnswer(_ sdp: String) async throws {
        if let answerFailure { throw answerFailure }
        appliedAnswer = sdp
        if startsSession {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.deliver(#"{"type":"session.started","session":{"id":"live_test"}}"#) }
            }
        }
    }

    func send(_ text: String) -> Bool {
        guard channelOpen else { return false }
        sent.append(text)
        if confirmsClose, text.contains("\"session.close\"") {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.deliver(#"{"type":"session.closed","reason":"close_requested","usage":{"seconds":42.0}}"#) }
            }
        }
        return true
    }

    func setMicEnabled(_ enabled: Bool) { micEnabled = enabled }
    func close() async { closeCalls += 1 }

    func deliver(_ json: String) { onMessage?(json) }

    /// Everything sent so far, parsed.
    var sentObjects: [[String: Any]] {
        sent.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    func sent(ofType type: String) -> [[String: Any]] {
        sentObjects.filter { ($0["type"] as? String) == type }
    }
}

@MainActor
final class LiveVoiceTests: XCTestCase {
    private var directory: URL!
    private var log: SessionLog!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-voice-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = SessionLog(directory: directory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let answer = LiveSessionResponse(
        sessionId: "live_test", sdp: "v=0\r\nANSWER", model: "gpt-live-1", voice: "gleam", latencyMs: 900, requestId: "r1"
    )

    private func makeVoice(
        _ transport: FakeLiveTransport,
        microphone: Bool = true,
        createSession: @escaping (LiveSessionRequest) async throws -> LiveSessionResponse = { _ in LiveVoiceTests.answer },
        config: LiveVoice.Config = LiveVoice.Config()
    ) -> LiveVoice {
        var fast = config
        fast.delegationSettle = 0.05
        fast.housekeepingInterval = 0.05
        return LiveVoice(problemID: "u3-01", appSessionID: "app-1", transport: transport, createSession: createSession,
                         ensureMicrophone: { microphone }, log: log, config: fast)
    }

    /// Connects and checks it worked (XCTAssert cannot take an awaited expression).
    private func connected(_ voice: LiveVoice, greet: Bool = false, line: UInt = #line) async {
        let failure = await voice.connect(greet: greet)
        XCTAssertNil(failure, "connect failed: \(failure?.reason ?? "")", line: line)
    }

    private func logTypes() -> [String] {
        _ = log.exportURL()   // waits for pending writes
        let text = (try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            ((try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any])?["type"] as? String
        }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    // MARK: - Connecting

    func testConnectSendsOurOfferToTheServerAppliesTheAnswerAndGreetsOnce() async {
        let transport = FakeLiveTransport()
        var request: LiveSessionRequest?
        let voice = makeVoice(transport, createSession: { req in request = req; return Self.answer })
        let failure = await voice.connect(greet: true)
        XCTAssertNil(failure)
        XCTAssertEqual(voice.state, .connected)
        XCTAssertEqual(request, LiveSessionRequest(sessionId: "app-1", problemId: "u3-01", sdp: "v=0\r\nOFFER"))
        XCTAssertEqual(transport.appliedAnswer, "v=0\r\nANSWER")
        let greetings = transport.sent(ofType: "session.commentary.append")
        XCTAssertEqual(greetings.count, 1)
        XCTAssertTrue(greetings.first?["delegation_id"] is NSNull)
        XCTAssertTrue(logTypes().contains("live_connected"))
        await voice.close(reason: "test_done")
    }

    func testReconnectingAfterAnIdleCloseDoesNotGreetAgain() async {
        let transport = FakeLiveTransport()
        let voice = makeVoice(transport)
        await connected(voice)
        XCTAssertTrue(transport.sent(ofType: "session.commentary.append").isEmpty)
        await voice.close(reason: "test_done")
    }

    func testNoMicrophonePermissionFailsWithItsReasonAndTearsTheTransportDown() async {
        let transport = FakeLiveTransport()
        let voice = makeVoice(transport, microphone: false)
        let failure = await voice.connect(greet: true)
        XCTAssertEqual(failure, LiveFailure(reason: "microphone_denied"))
        XCTAssertEqual(voice.state, .closed(reason: "microphone_denied"))
        XCTAssertEqual(transport.closeCalls, 1)
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testAServerRefusalIsReportedWithItsHttpStatus() async {
        let transport = FakeLiveTransport()
        let voice = makeVoice(transport, createSession: { _ in throw TutorError.serverUnavailable(status: 503, reason: "OPENAI_API_KEY is not set") })
        let failure = await voice.connect(greet: true)
        XCTAssertEqual(failure, LiveFailure(reason: "session_request_failed:http_503"))
        XCTAssertEqual(transport.closeCalls, 1)
        XCTAssertNil(transport.appliedAnswer, "no answer to apply when the server refused")
    }

    func testAnOfferThatCannotBeMadeFails() async {
        let transport = FakeLiveTransport()
        transport.offer = .failure(LiveFailure(reason: "ice_gathering_timeout"))
        let failure = await makeVoice(transport).connect(greet: true)
        XCTAssertEqual(failure, LiveFailure(reason: "offer_failed:ice_gathering_timeout"))
    }

    func testARejectedAnswerFails() async {
        let transport = FakeLiveTransport()
        transport.answerFailure = LiveFailure(reason: "set_remote_description_failed")
        let failure = await makeVoice(transport).connect(greet: true)
        XCTAssertEqual(failure, LiveFailure(reason: "answer_rejected:set_remote_description_failed"))
    }

    func testASessionThatNeverStartsTimesOut() async {
        let transport = FakeLiveTransport()
        transport.startsSession = false
        var config = LiveVoice.Config()
        config.startTimeout = 0.3
        let failure = await makeVoice(transport, config: config).connect(greet: true)
        XCTAssertEqual(failure, LiveFailure(reason: "no_session_started_within_0s"))
        XCTAssertEqual(transport.closeCalls, 1)
    }

    // MARK: - Delegation (GPT-Live cannot see the page)

    func testADelegationReachesTheAppWithTheStudentsWordsAndTheAnswerGoesBackWithItsId() async {
        let transport = FakeLiveTransport()
        let voice = makeVoice(transport)
        await connected(voice)
        var received: LiveVoice.Delegation?
        voice.onDelegation = { received = $0 }

        transport.deliver(#"{"type":"session.input_transcript.delta","delta":"Can you check","start_ms":0,"end_ms":200}"#)
        transport.deliver(#"{"type":"session.input_transcript.delta","delta":" my second line?","start_ms":200,"end_ms":400}"#)
        transport.deliver(#"{"type":"session.delegation.created","delegation":{"id":"item_1","type":"delegation","target":"client"}}"#)
        await waitUntil("the delegation reaches the app") { received != nil }
        XCTAssertEqual(received?.id, "item_1")
        XCTAssertEqual(received?.question, "Can you check my second line?")

        XCTAssertTrue(voice.answerDelegation(id: "item_1", text: "Line two is wrong."))
        let answers = transport.sent(ofType: "session.commentary.append").filter { ($0["delegation_id"] as? String) == "item_1" }
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first?["content"] as? String, "Line two is wrong.")
        XCTAssertFalse(voice.isStillWaiting(on: "item_1"))
        XCTAssertFalse(voice.answerDelegation(id: "item_1", text: "again"), "a delegation is answered once")
        await voice.close(reason: "test_done")
    }

    func testADelegationFromAnotherTargetIsIgnored() async {
        let transport = FakeLiveTransport()
        let voice = makeVoice(transport)
        await connected(voice)
        var received = false
        voice.onDelegation = { _ in received = true }
        transport.deliver(#"{"type":"session.delegation.created","delegation":{"id":"item_2","type":"delegation","target":"responses"}}"#)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(received)
        XCTAssertFalse(voice.isStillWaiting(on: "item_2"))
        await voice.close(reason: "test_done")
    }

    func testAFailedDelegationTellsTheModelInsteadOfLeavingItWaiting() async {
        let transport = FakeLiveTransport()
        let voice = makeVoice(transport)
        await connected(voice)
        voice.onDelegation = { _ in }
        transport.deliver(#"{"type":"session.delegation.created","delegation":{"id":"item_3","type":"delegation","target":"client"}}"#)
        XCTAssertTrue(voice.failDelegation(id: "item_3", reason: "it took too long"))
        let told = transport.sent(ofType: "session.commentary.append").first { ($0["delegation_id"] as? String) == "item_3" }
        XCTAssertTrue((told?["content"] as? String)?.contains("it took too long") ?? false)
        await voice.close(reason: "test_done")
    }

    /// Seen in the headless run on 2026-11-13: a hint sent while a delegation was pending replaced the page report.
    func testAHintArrivingDuringADelegationWaitsForTheAnswerAndThenFollowsIt() async {
        let transport = FakeLiveTransport()
        let voice = makeVoice(transport)
        await connected(voice)
        voice.onDelegation = { _ in }
        transport.deliver(#"{"type":"session.delegation.created","delegation":{"id":"item_4","type":"delegation","target":"client"}}"#)

        XCTAssertTrue(voice.say("Take another look at line two.", purpose: "hint"), "held counts as accepted")
        XCTAssertTrue(transport.sent(ofType: "session.commentary.append").isEmpty, "nothing is spoken while the page is being read")

        voice.answerDelegation(id: "item_4", text: "Line one is written.")
        await waitUntil("the held hint is released after the answer") {
            transport.sent(ofType: "session.commentary.append").count == 2
        }
        let contents = transport.sent(ofType: "session.commentary.append").compactMap { $0["content"] as? String }
        XCTAssertEqual(contents, ["Line one is written.", "Take another look at line two."], "the answer first, then the hint")
        await voice.close(reason: "test_done")
    }

    func testAHintWithNoDelegationPendingGoesOutAtOnce() async {
        let transport = FakeLiveTransport()
        let voice = makeVoice(transport)
        await connected(voice)
        XCTAssertTrue(voice.say("Check the sign.", purpose: "hint"))
        XCTAssertEqual(transport.sent(ofType: "session.commentary.append").count, 1)
        await voice.close(reason: "test_done")
    }

    // MARK: - Taking a hint back ("Not a mistake")

    func testAHintStillHeldBehindAPageReportIsDroppedAndNeverSpoken() async {
        let transport = FakeLiveTransport()
        let voice = makeVoice(transport)
        await connected(voice)
        voice.onDelegation = { _ in }
        transport.deliver(#"{"type":"session.delegation.created","delegation":{"id":"item_7","type":"delegation","target":"client"}}"#)
        XCTAssertTrue(voice.say("Take another look at line two.", purpose: "hint"))

        XCTAssertEqual(voice.retractHint(reason: "disputed"), ["held_dropped"])

        voice.answerDelegation(id: "item_7", text: "Line one is written.")
        try? await Task.sleep(nanoseconds: 400_000_000)
        let spoken = transport.sent(ofType: "session.commentary.append").compactMap { $0["content"] as? String }
        XCTAssertEqual(spoken, ["Line one is written."], "only the page report; the dismissed hint is gone for good")
        XCTAssertTrue(logTypes().contains("live_hint_dropped"))
        await voice.close(reason: "test_done")
    }

    func testAHintAlreadySentCannotBeRecalledAndTheCallerIsToldWhichCaseItWas() async {
        let transport = FakeLiveTransport()
        let voice = makeVoice(transport)
        await connected(voice)
        XCTAssertTrue(voice.say("Check the sign.", purpose: "hint"))

        XCTAssertEqual(voice.retractHint(reason: "disputed"), ["sent_already_said_context_only"], "no tutor speech since: it was already said")
        XCTAssertTrue(logTypes().contains("live_hint_retract_after_send"))
        XCTAssertEqual(voice.retractHint(reason: "disputed"), [], "taken back once")

        XCTAssertTrue(voice.say("Check the sign again.", purpose: "hint"))
        transport.deliver(#"{"type":"session.output_transcript.delta","delta":"Take another"}"#)
        XCTAssertEqual(voice.retractHint(reason: "disputed"), ["sent_while_speaking_context_only"], "the tutor is mid-sentence")
        await voice.close(reason: "test_done")
    }

    func testOnlyAHintIsTakenBackNotOtherSpeech() async {
        let transport = FakeLiveTransport()
        let voice = makeVoice(transport)
        await connected(voice)
        XCTAssertTrue(voice.say("Looks good so far.", purpose: "check_ok"))
        XCTAssertEqual(voice.retractHint(reason: "disputed"), [])
        await voice.close(reason: "test_done")
    }

    func testTheLiveSessionRequestCarriesTheTypedProblemOnlyWhenThereIsOne() async {
        for text in [nil, "7x - 4 = 3x + 16"] as [String?] {
            let transport = FakeLiveTransport()
            var request: LiveSessionRequest?
            let voice = LiveVoice(problemID: text == nil ? "u3-01" : "own:bc-math-9-unit-3", problemText: text, appSessionID: "app-1",
                                  transport: transport, createSession: { req in request = req; return Self.answer },
                                  ensureMicrophone: { true }, log: log)
            _ = await voice.connect(greet: false)
            XCTAssertEqual(request?.problemText, text)
            await voice.close(reason: "test_done")
        }
    }

    func testSayReportsFalseWhenThereIsNoLiveSessionSoTheCallerSpeaksTheOldWay() async {
        let transport = FakeLiveTransport()
        let voice = makeVoice(transport)
        XCTAssertFalse(voice.say("Check the sign.", purpose: "hint"), "not connected yet")
        await connected(voice)
        await voice.close(reason: "test_done")
        XCTAssertFalse(voice.say("Check the sign.", purpose: "hint"), "closed")
    }

    func testPageContextIsSentAsQuietThinkingNotSpeech() async {
        let transport = FakeLiveTransport()
        let voice = makeVoice(transport)
        await connected(voice)
        XCTAssertTrue(voice.pushContext("Page check just now: no problem.", label: "look_verdict"))
        XCTAssertEqual(transport.sent(ofType: "session.thinking.append").count, 1)
        XCTAssertTrue(transport.sent(ofType: "session.commentary.append").isEmpty)
        await voice.close(reason: "test_done")
    }

    // MARK: - Mute

    func testMutingSilencesTheLocalTrackAndTellsTheSession() async {
        let transport = FakeLiveTransport()
        let voice = makeVoice(transport)
        await connected(voice)
        voice.setMic(on: false)
        XCTAssertFalse(transport.micEnabled)
        XCTAssertFalse(voice.micOn)
        XCTAssertEqual(transport.sent(ofType: "session.input_audio.mute").count, 1)
        voice.setMic(on: true)
        XCTAssertTrue(transport.micEnabled)
        XCTAssertEqual(transport.sent(ofType: "session.input_audio.unmute").count, 1)
        await voice.close(reason: "test_done")
    }

    // MARK: - Ending

    func testClosingSendsSessionCloseWaitsForConfirmationAndReleasesTheTransportWithoutNotifyingTheApp() async {
        let transport = FakeLiveTransport()
        let voice = makeVoice(transport)
        await connected(voice)
        var endedReasons: [String] = []
        voice.onEnded = { endedReasons.append($0) }
        await voice.close(reason: "problem_closed")
        XCTAssertEqual(transport.sent(ofType: "session.close").count, 1)
        XCTAssertEqual(voice.state, .closed(reason: "problem_closed"))
        XCTAssertEqual(voice.usageSeconds, 42, "final usage comes from session.closed")
        XCTAssertEqual(transport.closeCalls, 1)
        XCTAssertTrue(endedReasons.isEmpty, "the app asked for this close, so it is not told about it")
    }

    func testClosingGivesUpWaitingWhenTheSessionNeverConfirms() async {
        let transport = FakeLiveTransport()
        transport.confirmsClose = false
        var config = LiveVoice.Config()
        config.closeTimeout = 0.2
        let voice = makeVoice(transport, config: config)
        await connected(voice)
        await voice.close(reason: "problem_closed")
        XCTAssertEqual(voice.state, .closed(reason: "problem_closed"))
        XCTAssertEqual(transport.closeCalls, 1)
    }

    func testALostConnectionTellsTheApp() async {
        let transport = FakeLiveTransport()
        let voice = makeVoice(transport)
        await connected(voice)
        var ended: String?
        voice.onEnded = { ended = $0 }
        transport.onClosed?("peer_failed")
        await waitUntil("the app is told") { ended != nil }
        XCTAssertEqual(ended, "connection_lost:peer_failed")
        XCTAssertEqual(transport.closeCalls, 1)
    }

    func testTheServerEndingTheSessionTellsTheApp() async {
        let transport = FakeLiveTransport()
        let voice = makeVoice(transport)
        await connected(voice)
        var ended: String?
        voice.onEnded = { ended = $0 }
        transport.deliver(#"{"type":"session.closed","reason":"expired","usage":{"seconds":7200.0}}"#)
        await waitUntil("the app is told") { ended != nil }
        XCTAssertEqual(ended, "server_closed:expired")
        XCTAssertEqual(voice.usageSeconds, 7200)
    }

    func testIdleSessionClosesItselfAndTellsTheApp() async {
        let transport = FakeLiveTransport()
        var config = LiveVoice.Config()
        config.idleLimit = 0.3
        let voice = makeVoice(transport, config: config)
        await connected(voice)
        var ended: String?
        voice.onEnded = { ended = $0 }
        await waitUntil("the idle close", timeout: 4) { ended != nil }
        XCTAssertEqual(ended, "idle")
        XCTAssertEqual(transport.sent(ofType: "session.close").count, 1)
        XCTAssertEqual(transport.closeCalls, 1)
    }

    func testActivityKeepsTheSessionFromGoingIdle() async {
        let transport = FakeLiveTransport()
        var config = LiveVoice.Config()
        // A 1.5 s limit with activity every 0.1 s for 4 s: longer than the limit, so only the resets keep it open, and a 15x margin
        // per gap so a busy CI runner's late wake-up cannot fake an idle (0.4 s limit flaked on GitHub's macos-26, run 46060115753).
        config.idleLimit = 1.5
        let voice = makeVoice(transport, config: config)
        await connected(voice)
        var ended: String?
        voice.onEnded = { ended = $0 }
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            voice.noteActivity()
        }
        XCTAssertNil(ended, "ink or speech inside the limit resets the clock")
        await voice.close(reason: "test_done")
    }

    // MARK: - Logging

    func testTheLogNamesEveryDecisionAndNeverHoldsTheOfferOrAnswerText() async {
        let transport = FakeLiveTransport()
        let voice = makeVoice(transport)
        await connected(voice, greet: true)
        voice.setMic(on: false)
        await voice.close(reason: "problem_closed")
        let types = logTypes()
        for expected in ["live_connect", "live_offer_ready", "live_answer_received", "live_connected", "live_commentary_sent", "live_mic", "live_disconnected"] {
            XCTAssertTrue(types.contains(expected), "log has \(expected); got \(types)")
        }
        _ = log.exportURL()
        let text = (try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? ""
        XCTAssertFalse(text.contains("OFFER"), "the SDP offer is never logged")
        XCTAssertFalse(text.contains("ANSWER"), "the SDP answer is never logged")
    }
}
