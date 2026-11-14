import Foundation

/// The tutor server, behind a protocol so UI tests can swap in a scripted tutor.
protocol TutorClient {
    func watch(_ request: WatchRequest) async throws -> WatchResponse
    func ask(_ request: AskRequest) async throws -> AskResponse
    /// The page reader the live voice delegates to (text question + page picture in, report out).
    func consult(_ request: ConsultRequest) async throws -> ConsultResponse
    /// Relays the WebRTC offer to OpenAI through our server; the OpenAI key stays on the server.
    func createLiveSession(_ request: LiveSessionRequest) async throws -> LiveSessionResponse
    /// GET /api/me: checks the code, says whether live voice is in the plan, reports the allowance. Free, not metered.
    func me() async throws -> MeResponse
    /// POST /api/heartbeat: tells the server a problem is open and the student is active.
    func heartbeat(_ request: HeartbeatRequest) async throws -> HeartbeatResponse
}

/// Wraps a client so every reply's allowance, and every refusal about codes or hours, reaches the `StudentAccount`.
/// Screens never have to remember to do this themselves. `me()` is passed straight through: the account makes that call
/// itself and handles the result.
struct MeteredTutorClient: TutorClient {
    let inner: TutorClient
    let account: StudentAccount

    func watch(_ request: WatchRequest) async throws -> WatchResponse {
        try await report { try await inner.watch(request) } allowance: { $0.allowance }
    }

    func ask(_ request: AskRequest) async throws -> AskResponse {
        try await report { try await inner.ask(request) } allowance: { $0.allowance }
    }

    func consult(_ request: ConsultRequest) async throws -> ConsultResponse {
        try await report { try await inner.consult(request) } allowance: { $0.allowance }
    }

    func createLiveSession(_ request: LiveSessionRequest) async throws -> LiveSessionResponse {
        try await report { try await inner.createLiveSession(request) } allowance: { $0.allowance }
    }

    func heartbeat(_ request: HeartbeatRequest) async throws -> HeartbeatResponse {
        try await report { try await inner.heartbeat(request) } allowance: { $0.allowance }
    }

    func me() async throws -> MeResponse {
        try await inner.me()
    }

    private func report<Reply>(_ call: () async throws -> Reply, allowance: (Reply) -> Allowance?) async throws -> Reply {
        do {
            let reply = try await call()
            if let seen = allowance(reply) {
                await account.apply(allowance: seen, source: "reply")
            }
            return reply
        } catch {
            if let tutorError = error as? TutorError {
                await account.handle(serverError: tutorError)
            }
            throw error
        }
    }
}

/// Used when SERVER_URL is not set. The student can still write; every call says why it cannot work.
struct UnconfiguredTutorClient: TutorClient {
    let reason: String

    func watch(_ request: WatchRequest) async throws -> WatchResponse {
        throw TutorError.notConfigured(reason: reason)
    }

    func ask(_ request: AskRequest) async throws -> AskResponse {
        throw TutorError.notConfigured(reason: reason)
    }

    func consult(_ request: ConsultRequest) async throws -> ConsultResponse {
        throw TutorError.notConfigured(reason: reason)
    }

    func createLiveSession(_ request: LiveSessionRequest) async throws -> LiveSessionResponse {
        throw TutorError.notConfigured(reason: reason)
    }

    func me() async throws -> MeResponse {
        throw TutorError.notConfigured(reason: reason)
    }

    func heartbeat(_ request: HeartbeatRequest) async throws -> HeartbeatResponse {
        throw TutorError.notConfigured(reason: reason)
    }
}

/// Deterministic in-process tutor for UI tests (`--scripted-client`). It mirrors the server's scripted mode
/// (server/README.md): on the planted problem u3-04 it interrupts on line 2 when line 2 exists and no earlier
/// interrupt on line 2 is in the history; every other look, and every other problem, waits.
struct ScriptedTutorClient: TutorClient {
    static let plantedProblemID = "u3-04"
    static let latencyNanoseconds: UInt64 = 300_000_000

    /// A plain, healthy allowance (8 hours, a few minutes used) so the screens have something to show in scripted runs.
    static let allowance = Allowance(
        month: "2026-11", usedSeconds: 120, capSeconds: 28_800, remainingSeconds: 28_680, remainingMinutes: 478,
        percentUsed: 0.4, state: .ok
    )

    func me() async throws -> MeResponse {
        MeResponse(plan: PlanInfo(live: false, capMinutes: 480), allowance: Self.allowance, requestId: "scripted-me")
    }

    func heartbeat(_ request: HeartbeatRequest) async throws -> HeartbeatResponse {
        HeartbeatResponse(ok: true, allowance: Self.allowance, requestId: "scripted-heartbeat")
    }

    func watch(_ request: WatchRequest) async throws -> WatchResponse {
        try await Task.sleep(nanoseconds: Self.latencyNanoseconds)
        let hasLineTwo = request.lines.contains { $0.index == 2 }
        let alreadyInterruptedLineTwo = request.history.contains { $0.action == "interrupt" && $0.line == 2 }
        if request.problemId == Self.plantedProblemID && hasLineTwo && !alreadyInterruptedLineTwo {
            return WatchResponse(
                action: "interrupt",
                line: 2,
                reason: "scripted: planted mistake on line 2",
                hintSpoken: "Take another look at line two. Check the signs.",
                hintWritten: "Check the signs here",
                drawingRevision: request.drawingRevision,
                requestId: "scripted-\(request.drawingRevision)",
                model: "scripted",
                latencyMs: Int(Self.latencyNanoseconds / 1_000_000)
            )
        }
        return WatchResponse(
            action: "wait",
            line: nil,
            reason: "scripted: nothing to flag",
            hintSpoken: nil,
            hintWritten: nil,
            drawingRevision: request.drawingRevision,
            requestId: "scripted-\(request.drawingRevision)",
            model: "scripted",
            latencyMs: Int(Self.latencyNanoseconds / 1_000_000)
        )
    }

    func consult(_ request: ConsultRequest) async throws -> ConsultResponse {
        try await Task.sleep(nanoseconds: Self.latencyNanoseconds)
        return ConsultResponse(
            answerText: "Scripted page report. Look at your last line.",
            drawingRevision: request.drawingRevision,
            requestId: "scripted-consult",
            model: "scripted",
            latencyMs: Int(Self.latencyNanoseconds / 1_000_000)
        )
    }

    /// Scripted runs never open a live voice session (no network in UI tests), so this is a refusal with a reason.
    func createLiveSession(_ request: LiveSessionRequest) async throws -> LiveSessionResponse {
        throw TutorError.notConfigured(reason: "scripted client has no live session")
    }

    func ask(_ request: AskRequest) async throws -> AskResponse {
        try await Task.sleep(nanoseconds: Self.latencyNanoseconds)
        return AskResponse(
            transcript: nil,
            answerText: "Try getting the x terms on one side first.",
            requestId: "scripted-ask",
            model: "scripted",
            latencyMs: Int(Self.latencyNanoseconds / 1_000_000)
        )
    }
}
