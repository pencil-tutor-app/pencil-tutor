import Foundation

/// One GPT-Live voice session for one problem screen. Single use: connect once, close once. `TutorSession` owns it.
///
/// What it does: sets the connection up (microphone permission, WebRTC offer, our server relays it to OpenAI, apply the
/// answer, wait for `session.started`), keeps the transcript, turns `session.delegation.created` into a request for the
/// app to answer, sends hints and context in, handles mute, closes when idle, and logs every decision.
///
/// It never holds the OpenAI key. The key stays on the server (`POST /api/live-session`).
@MainActor
final class LiveVoice {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case closed(reason: String)
    }

    /// A request from GPT-Live to look at the page. The app answers with `answerDelegation` or `failDelegation`.
    struct Delegation: Equatable {
        let id: String
        let question: String
        let recent: [ConsultTurnWire]
        let requestedAt: Date
    }

    struct Config {
        /// No ink and no speech for this long closes the session (cost). A chosen default, not a measured one.
        var idleLimit: TimeInterval = 300
        var startTimeout: TimeInterval = 12
        var closeTimeout: TimeInterval = 3
        /// Late transcript fragments of the last words arrive just after the delegation event; wait for them.
        var delegationSettle: TimeInterval = 0.6
        /// A hint held back while a delegation is pending goes out once the tutor has been quiet, but not later than this.
        var heldHintMaxWait: TimeInterval = 20
        var heldHintMaxAge: TimeInterval = 30
        var housekeepingInterval: TimeInterval = 0.5
        var quietBeforeHeldHint: TimeInterval = 1.6
        var greeting = "Say hello in one short sentence: tell the student you are here and will watch their page quietly, and that they can just talk to you. Then stop and listen."
    }

    private(set) var state: State = .idle
    private(set) var micOn = true
    private(set) var usageSeconds: Double = 0
    private(set) var liveSessionID: String?

    /// GPT-Live wants the page looked at.
    var onDelegation: ((Delegation) -> Void)?
    /// The session ended on its own (dropped, expired, idle, ended by OpenAI). Not called for `close(reason:)`.
    var onEnded: ((String) -> Void)?

    private let problemID: String
    private let appSessionID: String
    private let transport: LiveTransport
    private let createSession: (LiveSessionRequest) async throws -> LiveSessionResponse
    private let ensureMicrophone: () async -> Bool
    private let log: SessionLog
    private let now: () -> Date
    private let config: Config

    private var transcript = LiveTranscript()
    private var eventCounter = 0
    private var sentAt: [String: Date] = [:]
    private var pendingDelegations: [String: Date] = [:]
    private var held: (text: String, purpose: String, at: Date)?
    private var heldReleaseTask: Task<Void, Never>?
    private var housekeeping: Task<Void, Never>?
    private var sawStarted = false
    private var sawClosedEvent = false
    private var closeReasonFromServer: String?
    private var lastActivityAt: Date
    /// When the student last spoke (the live session transcribed their voice). Counted as working time via the heartbeat.
    private(set) var lastStudentSpeechAt: Date?
    private var lastTutorFragmentAt: Date?
    private var lastUsageLoggedAt: Double = -100
    private var connectStartedAt: Date
    private var ending = false

    init(problemID: String, appSessionID: String, transport: LiveTransport,
         createSession: @escaping (LiveSessionRequest) async throws -> LiveSessionResponse,
         ensureMicrophone: @escaping () async -> Bool,
         log: SessionLog, now: @escaping () -> Date = { Date() }, config: Config = Config()) {
        self.problemID = problemID
        self.appSessionID = appSessionID
        self.transport = transport
        self.createSession = createSession
        self.ensureMicrophone = ensureMicrophone
        self.log = log
        self.now = now
        self.config = config
        self.lastActivityAt = now()
        self.connectStartedAt = now()
        transport.onMessage = { [weak self] text in self?.handle(text) }
        transport.onClosed = { [weak self] reason in self?.transportClosed(reason: reason) }
    }

    // MARK: - Connect

    /// Nil on success. On failure the transport is already torn down and the failure says why.
    func connect(greet: Bool) async -> LiveFailure? {
        guard state == .idle else { return LiveFailure(reason: "already_started") }
        state = .connecting
        connectStartedAt = now()
        log.record("live_connect", ["problem_id": problemID, "greet": greet])

        guard await ensureMicrophone() else { return await failConnect("microphone_denied") }

        let offer: String
        do { offer = try await transport.prepareOffer() } catch {
            return await failConnect("offer_failed:\(Self.label(error))")
        }
        log.record("live_offer_ready", ["sdp_chars": offer.count, "elapsed_ms": elapsedMs()])

        let answer: LiveSessionResponse
        do {
            answer = try await createSession(LiveSessionRequest(sessionId: appSessionID, problemId: problemID, sdp: offer))
        } catch {
            let (_, detail) = TutorError.describe(error)
            log.record("live_server_refused", ["detail": detail, "elapsed_ms": elapsedMs()])
            return await failConnect("session_request_failed:\(Self.serverLabel(error))")
        }
        liveSessionID = answer.sessionId
        log.record("live_answer_received", [
            "live_session": answer.sessionId, "model": answer.model ?? "?", "voice": answer.voice ?? "?",
            "server_ms": answer.latencyMs ?? -1, "elapsed_ms": elapsedMs()
        ])

        do { try await transport.applyAnswer(answer.sdp) } catch {
            return await failConnect("answer_rejected:\(Self.label(error))")
        }

        let deadline = now().addingTimeInterval(config.startTimeout)
        while !sawStarted, state == .connecting, now() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard state == .connecting else {
            return await failConnect("transport_closed_while_connecting")
        }
        guard sawStarted else { return await failConnect("no_session_started_within_\(Int(config.startTimeout))s") }

        state = .connected
        lastActivityAt = now()
        log.record("live_connected", [
            "latency_ms": elapsedMs(), "live_session": answer.sessionId, "model": answer.model ?? "?", "voice": answer.voice ?? "?"
        ])
        startHousekeeping()
        if greet { _ = sendCommentary(config.greeting, delegationID: nil, purpose: "greeting") }
        return nil
    }

    private func failConnect(_ reason: String) async -> LiveFailure {
        log.record("live_connect_failed", ["reason": reason, "elapsed_ms": elapsedMs()])
        state = .closed(reason: reason)
        await transport.close()
        return LiveFailure(reason: reason)
    }

    // MARK: - Talking to the session

    /// Tells the student something through the live voice (a watch hint, the "looks good" verdict). The model may
    /// paraphrase it. False when there is no live session, so the caller speaks it the old way. While a delegation is
    /// pending the text is held and sent after the answer: in the headless run on 2026-11-13 a hint that arrived mid-delegation
    /// replaced the page report instead of following it.
    @discardableResult
    func say(_ text: String, purpose: String) -> Bool {
        guard state == .connected else { return false }
        if !pendingDelegations.isEmpty {
            held = (text, purpose, now())
            log.record("live_hint_held", ["purpose": purpose, "chars": text.count, "pending_delegations": pendingDelegations.count])
            return true
        }
        return sendCommentary(text, delegationID: nil, purpose: purpose)
    }

    /// Facts for the model to know without saying them (the latest page check).
    @discardableResult
    func pushContext(_ text: String, label: String) -> Bool {
        guard state == .connected else { return false }
        let id = nextEventID()
        let ok = send(.thinking(eventID: id, text: text))
        var fields: [String: Any] = ["label": label, "chars": text.count, "event_id": id, "sent": ok]
        if TutorSession.logsWords { fields["text"] = text }
        log.record("live_context_pushed", fields)
        return ok
    }

    /// The page report for a delegation. Dropped (and logged) if the session ended meanwhile.
    @discardableResult
    func answerDelegation(id: String, text: String, stale: Bool = false) -> Bool {
        guard let requestedAt = pendingDelegations.removeValue(forKey: id) else {
            log.record("live_delegation_dropped", ["delegation_id": id, "reason": "not_pending"])
            return false
        }
        guard state == .connected else {
            log.record("live_delegation_dropped", ["delegation_id": id, "reason": "session_not_connected"])
            return false
        }
        let ms = Int(now().timeIntervalSince(requestedAt) * 1000)
        let ok = sendCommentary(text, delegationID: id, purpose: "delegation_answer")
        log.record("live_delegation_answered", ["delegation_id": id, "latency_ms": ms, "chars": text.count, "stale": stale, "sent": ok])
        releaseHeldHintWhenQuiet()
        return ok
    }

    /// The page could not be read. Tell the model so it can tell the student, instead of leaving it waiting.
    @discardableResult
    func failDelegation(id: String, reason: String) -> Bool {
        guard let requestedAt = pendingDelegations.removeValue(forKey: id), state == .connected else {
            log.record("live_delegation_dropped", ["delegation_id": id, "reason": state == .connected ? "not_pending" : "session_not_connected"])
            return false
        }
        let ms = Int(now().timeIntervalSince(requestedAt) * 1000)
        let ok = sendCommentary(LiveContext.consultFailed(reason: reason), delegationID: id, purpose: "delegation_failed")
        log.record("live_delegation_failed", ["delegation_id": id, "latency_ms": ms, "reason": reason, "sent": ok])
        releaseHeldHintWhenQuiet()
        return ok
    }

    func isStillWaiting(on delegationID: String) -> Bool {
        state == .connected && pendingDelegations[delegationID] != nil
    }

    /// Mute or unmute the student's microphone. The local track goes silent at once; the session is told too.
    func setMic(on: Bool) {
        micOn = on
        transport.setMicEnabled(on)
        noteActivity()
        guard state == .connected else {
            log.record("live_mic", ["on": on, "session_told": false, "why": "not connected"])
            return
        }
        let id = nextEventID()
        let ok = send(on ? .unmute(eventID: id) : .mute(eventID: id))
        log.record("live_mic", ["on": on, "session_told": ok, "event_id": id])
    }

    /// Ink or speech happened: the session is not idle.
    func noteActivity() {
        lastActivityAt = now()
    }

    /// Ends the session at the app's request (problem closed, app backgrounded, fallback). Waits briefly for the
    /// session's own `session.closed` so final usage is confirmed.
    func close(reason: String) async {
        guard !ending else { return }
        ending = true
        await closeGracefully(reason: reason, notify: false)
    }

    // MARK: - Events from the session

    func handle(_ text: String) {
        guard let event = LiveServerEvent.decode(text) else {
            log.record("live_event_unreadable", ["chars": text.count])
            return
        }
        switch event {
        case .started(let id):
            sawStarted = true
            if let id { liveSessionID = id }
        case .inputTranscript(let fragment):
            noteActivity()
            lastStudentSpeechAt = now()
            logFinished(transcript.add(.student, fragment: fragment, at: now()))
        case .outputTranscript(let fragment):
            noteActivity()
            lastTutorFragmentAt = now()
            logFinished(transcript.add(.tutor, fragment: fragment, at: now()))
        case .delegationCreated(let id, let target):
            noteActivity()
            handleDelegation(id: id, target: target)
        case .usage(let seconds):
            usageSeconds = seconds
            if seconds - lastUsageLoggedAt >= 15 {
                lastUsageLoggedAt = seconds
                log.record("live_usage", ["seconds": seconds])
            }
        case .muted(let clientEventID), .unmuted(let clientEventID):
            log.record("live_mic_acknowledged", ["event_id": clientEventID ?? "?", "ack_ms": ackMs(clientEventID)])
        case .appended(let kind, let clientEventID):
            log.record("live_context_acknowledged", ["kind": kind, "event_id": clientEventID ?? "?", "ack_ms": ackMs(clientEventID)])
        case .closed(let reason, let seconds):
            sawClosedEvent = true
            closeReasonFromServer = reason
            if let seconds { usageSeconds = seconds }
            if !ending && state == .connected {
                ending = true
                let why = "server_closed:\(reason ?? "unknown")"
                Task { await self.finish(reason: why, confirmed: true, notify: true) }
            }
        case .failure(let type, let code, let message, let clientEventID):
            var fields: [String: Any] = ["type": type ?? "?", "code": code ?? "?", "event_id": clientEventID ?? "none"]
            if TutorSession.logsWords { fields["message"] = String(message.prefix(200)) }
            log.record("live_error", fields)
        case .other(let type):
            log.record("live_event_other", ["event_type": type])
        }
    }

    private func handleDelegation(id: String, target: String?) {
        guard target == nil || target == "client" else {
            log.record("live_delegation_ignored", ["delegation_id": id, "target": target ?? "?"])
            return
        }
        guard state == .connected else {
            log.record("live_delegation_dropped", ["delegation_id": id, "reason": "session_not_connected"])
            return
        }
        pendingDelegations[id] = now()
        log.record("live_delegation_requested", ["delegation_id": id, "pending": pendingDelegations.count])
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.config.delegationSettle * 1_000_000_000))
            guard self.isStillWaiting(on: id) else { return }
            var question = self.transcript.takeQuestion()
            if question.isEmpty {
                question = "Please look at my page and tell me how I'm doing."
                self.log.record("live_delegation_question_empty", ["delegation_id": id])
            }
            let recent = self.transcript.recent()
            self.log.record("live_delegation_handed_to_app", [
                "delegation_id": id, "question_chars": question.count, "recent_turns": recent.count
            ])
            self.onDelegation?(Delegation(id: id, question: question, recent: recent, requestedAt: self.pendingDelegations[id] ?? self.now()))
        }
    }

    private func transportClosed(reason: String) {
        switch state {
        case .connecting:
            log.record("live_transport_closed", ["reason": reason, "during": "connect"])
            state = .closed(reason: reason)
        case .connected:
            guard !ending else { return }
            ending = true
            Task { await self.finish(reason: "connection_lost:\(reason)", confirmed: sawClosedEvent, notify: true) }
        case .idle, .closed:
            break
        }
    }

    // MARK: - Ending

    private func finish(reason: String, confirmed: Bool, notify: Bool) async {
        housekeeping?.cancel()
        heldReleaseTask?.cancel()
        held = nil
        logFinished(transcript.finishAll())
        let wasConnected = state == .connected
        if case .closed = state {} else { state = .closed(reason: reason) }
        log.record("live_disconnected", [
            "reason": reason, "usage_seconds": usageSeconds, "usage_confirmed": confirmed,
            "was_connected": wasConnected, "pending_delegations": pendingDelegations.count
        ])
        pendingDelegations = [:]
        await transport.close()
        if notify { onEnded?(reason) }
    }

    // MARK: - Housekeeping (quiet turns, idle close)

    private func startHousekeeping() {
        housekeeping?.cancel()
        housekeeping = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.config.housekeepingInterval * 1_000_000_000))
                if Task.isCancelled { return }
                self.logFinished(self.transcript.finishQuiet(at: self.now()))
                if self.state == .connected, !self.ending, self.pendingDelegations.isEmpty,
                   self.now().timeIntervalSince(self.lastActivityAt) >= self.config.idleLimit {
                    self.log.record("live_idle_close", ["idle_seconds": Int(self.now().timeIntervalSince(self.lastActivityAt))])
                    self.ending = true
                    // A separate task: closing cancels this housekeeping task, and the teardown must not be cancelled with it.
                    Task { await self.closeGracefully(reason: "idle", notify: true) }
                    return
                }
            }
        }
    }

    /// Sends `session.close` and waits for `session.closed` (OpenAI's documented close sequence) so the final usage is
    /// confirmed, but never longer than `closeTimeout`. `ending` is already set by the caller.
    private func closeGracefully(reason: String, notify: Bool) async {
        if state == .connected {
            let id = nextEventID()
            _ = send(.close(eventID: id))
            let deadline = now().addingTimeInterval(config.closeTimeout)
            while !sawClosedEvent, now() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        await finish(reason: reason, confirmed: sawClosedEvent, notify: notify)
    }

    private func releaseHeldHintWhenQuiet() {
        guard held != nil else { return }
        heldReleaseTask?.cancel()
        heldReleaseTask = Task { [weak self] in
            guard let self else { return }
            let started = self.now()
            while !Task.isCancelled, self.state == .connected {
                let quiet = self.lastTutorFragmentAt.map { self.now().timeIntervalSince($0) >= self.config.quietBeforeHeldHint } ?? true
                let waited = self.now().timeIntervalSince(started)
                if quiet || waited >= self.config.heldHintMaxWait { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard !Task.isCancelled, self.state == .connected, let hint = self.held, self.pendingDelegations.isEmpty else { return }
            self.held = nil
            let age = self.now().timeIntervalSince(hint.at)
            if age > self.config.heldHintMaxAge {
                self.log.record("live_hint_dropped", ["purpose": hint.purpose, "reason": "older_than_\(Int(self.config.heldHintMaxAge))s", "age_ms": Int(age * 1000)])
                return
            }
            self.log.record("live_hint_released", ["purpose": hint.purpose, "held_ms": Int(age * 1000)])
            _ = self.sendCommentary(hint.text, delegationID: nil, purpose: hint.purpose)
        }
    }

    // MARK: - Small helpers

    @discardableResult
    private func sendCommentary(_ text: String, delegationID: String?, purpose: String) -> Bool {
        let id = nextEventID()
        let ok = send(.commentary(eventID: id, delegationID: delegationID, text: text))
        var fields: [String: Any] = ["purpose": purpose, "chars": text.count, "event_id": id, "sent": ok, "for_delegation": delegationID != nil]
        if TutorSession.logsWords { fields["text"] = text }
        log.record("live_commentary_sent", fields)
        if !ok { log.record("live_send_failed", ["purpose": purpose, "event_id": id, "why": "data channel not open"]) }
        return ok
    }

    private func send(_ event: LiveClientEvent) -> Bool {
        sentAt[event.eventID] = now()
        return transport.send(event.json())
    }

    private func nextEventID() -> String {
        eventCounter += 1
        return "app_\(eventCounter)"
    }

    private func ackMs(_ clientEventID: String?) -> Int {
        guard let clientEventID, let sent = sentAt.removeValue(forKey: clientEventID) else { return -1 }
        return Int(now().timeIntervalSince(sent) * 1000)
    }

    private func elapsedMs() -> Int {
        Int(now().timeIntervalSince(connectStartedAt) * 1000)
    }

    private func logFinished(_ turns: [LiveTurn]) {
        for turn in turns where !turn.text.isEmpty {
            let type = turn.speaker == .student ? "student_said" : "tutor_said"
            var fields: [String: Any] = ["chars": turn.text.count]
            if TutorSession.logsWords { fields["text"] = turn.text }
            log.record(type, fields)
        }
    }

    private static func label(_ error: Error) -> String {
        if let failure = error as? LiveFailure { return failure.reason }
        return "error"
    }

    private static func serverLabel(_ error: Error) -> String {
        guard let tutor = error as? TutorError else { return "unexpected" }
        switch tutor {
        case .unauthorized: return "http_401"
        case .serverUnavailable(let status, _): return "http_\(status)"
        case .rejected(let status, _): return "http_\(status)"
        case .timedOut: return "timeout"
        case .offline: return "offline"
        case .notConfigured: return "not_configured"
        default: return "bad_reply"
        }
    }
}
