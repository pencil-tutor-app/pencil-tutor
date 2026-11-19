import Foundation

/// The tutor server, behind a protocol so UI tests can swap in a scripted tutor.
protocol TutorClient: MemoryAPI {
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

    func memoryStatus() async throws -> MemoryStatusResponse {
        try await report { try await inner.memoryStatus() } allowance: { $0.allowance }
    }

    func memoryAct(_ request: MemoryActionRequest) async throws -> MemoryActionResponse {
        try await report { try await inner.memoryAct(request) } allowance: { $0.allowance }
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
        // In a run that starts on the code screen (`--scripted-needs-code`) the student holds a free code, so the reply says so.
        MeResponse(plan: PlanInfo(live: false, capMinutes: 480), allowance: Self.allowance, requestId: "scripted-me",
                   free: LaunchOptions.scriptedNeedsCode ? FreeInfo(full: false) : nil)
    }

    /// The code the scripted server hands out for "Start free" (`--scripted-needs-code`). A real code has the same shape.
    static let freeCode = "FREE5ABC"

    /// What POST /api/free-code does, in the small: a short wait, then a code. Used by the Start free UI test.
    func createFreeCode() async throws -> FreeCodeResponse {
        try await Task.sleep(nanoseconds: Self.latencyNanoseconds)
        return FreeCodeResponse(code: Self.freeCode, capMinutes: 480, requestId: "scripted-free-code")
    }

    func heartbeat(_ request: HeartbeatRequest) async throws -> HeartbeatResponse {
        HeartbeatResponse(ok: true, allowance: Self.allowance, requestId: "scripted-heartbeat")
    }

    // MARK: Tutor memory (UI tests): offered only with --memory-on, like a server whose STUDENT_RECORD switch is on.

    /// The scripted state, shared by every copy of this struct. Mirrors the server's rules in the small.
    final class ScriptedMemory: @unchecked Sendable {
        var givenBy: String?
        var withdrawn = false
        var erased = false
        var consentAt = ""

        init() {
            if LaunchOptions.memoryAgreed {
                givenBy = "parent_guardian"
                consentAt = TimeText.iso(Date())
            }
        }
    }
    let memory = ScriptedMemory()

    func memoryStatus() async throws -> MemoryStatusResponse {
        guard LaunchOptions.memoryOn else { throw TutorError.rejected(status: 404, reason: "scripted: memory is not offered") }
        let now = TimeText.iso(Date())
        let consent: MemoryConsent? = memory.consentAt.isEmpty
            ? nil
            : MemoryConsent(granted: !memory.withdrawn, current: !memory.withdrawn, givenBy: memory.givenBy, recordedVia: "app",
                            noticeVersion: Self.scriptedNotice.version, at: memory.consentAt)
        let recent = memory.erased ? [] : [
            MemoryRecentAttempt(problemId: "u3-04", looks: 6, asks: 1, interrupts: 2, lastAt: now),
            MemoryRecentAttempt(problemId: "u3-01", looks: 4, asks: 0, interrupts: 0, lastAt: now),
        ]
        return MemoryStatusResponse(
            feature: "on", notice: Self.scriptedNotice, consent: consent,
            record: MemoryRecord(notes: memory.erased || memory.consentAt.isEmpty ? 0 : 2, recent: memory.consentAt.isEmpty ? [] : recent),
            requestId: "scripted-memory"
        )
    }

    func memoryAct(_ request: MemoryActionRequest) async throws -> MemoryActionResponse {
        try await Task.sleep(nanoseconds: 150_000_000)
        switch request.action {
        case "consent":
            guard request.attested == true, request.noticeVersion == Self.scriptedNotice.version else {
                throw TutorError.rejected(status: 409, reason: "notice_outdated")
            }
            memory.givenBy = request.givenBy
            memory.withdrawn = false
            memory.erased = false
            memory.consentAt = TimeText.iso(Date())
        case "withdraw":
            memory.withdrawn = true
            if request.erase == true { memory.erased = true }
        default:
            memory.erased = true
        }
        return MemoryActionResponse(ok: true, withdrawn: nil, deleted: MemoryDeleted(hints: 0, attempts: 0, notes: 0), requestId: "scripted-memory-act")
    }

    /// The same words as server/lib/record/notice.ts, so screenshots show the real screen.
    static let scriptedNotice = MemoryNotice(
        version: "2026-11-14.1",
        title: "Let the tutor remember?",
        intro: "Memory is optional. If you leave it off, the tutor works exactly the same. A parent or guardian decides for a student, or an adult student decides for themselves.",
        sections: [
            MemoryNoticeSection(heading: "What is remembered", body: "Which problems were worked on and when, how many times the tutor looked and stepped in (and on which line), how many questions were asked, and short notes Edward writes after a lesson. Not remembered: names, pictures of the page, recordings, or anything the student says or writes."),
            MemoryNoticeSection(heading: "Why", body: "So the tutor's hints can be worded in a way that suits the student. It never changes when the tutor speaks up. It is not used for ads, never sold, and not shared except with the services that run the tutor."),
            MemoryNoticeSection(heading: "Who sees it", body: "Edward. To word a hint, an AI service (OpenAI, in the United States) may also see Edward's notes for that one hint. The records are kept in a database service (Neon)."),
            MemoryNoticeSection(heading: "How long", body: "Until you erase it. Edward also deletes the memory of any code that has not been used for 12 months, by hand."),
            MemoryNoticeSection(heading: "See it, take it, erase it", body: "In Settings, \"What the tutor remembers\" shows what is stored and lets you turn memory off or erase it, at any time. Ask Edward for a copy of everything, including his notes."),
            MemoryNoticeSection(heading: "The voice is an AI", body: "The tutor you hear is a computer-generated voice, not a person talking to you live."),
        ],
        policyUrl: "https://pencil-tutor.vercel.app/api/privacy"
    )

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
