import Combine
import Foundation

/// Who is using the app and how much of the month is left.
///
/// Holds the student's code (in the Keychain between launches), the plan the server reports (is live voice included),
/// and the allowance. Every reply the server sends about hours, and every refusal about the code, ends up here, so the
/// problem screen only has to read `block`, `allowance` and `plan`.
///
/// Logging rule: the code itself never reaches the log; only `StudentCode.shortHash`.
@MainActor
final class StudentAccount: ObservableObject {
    enum Phase: Equatable {
        case needsCode
        case ready
    }

    /// Why the tutor has stopped watching and answering. Drawing keeps working in every case.
    enum Block: Equatable {
        case hoursUsedUp
        case codeTurnedOff
        /// A free code while all free codes together have used this month's money. Clears when the server says it is open again.
        case freeTutoringFull

        var message: String {
            switch self {
            case .hoursUsedUp: return AllowanceText.usedUp
            case .codeTurnedOff: return AllowanceText.codeTurnedOff
            case .freeTutoringFull: return AllowanceText.freeTutoringFull
            }
        }

        var logLabel: String {
            switch self {
            case .hoursUsedUp: return "hours_used_up"
            case .codeTurnedOff: return "code_turned_off"
            case .freeTutoringFull: return "free_tutoring_full"
            }
        }
    }

    @Published private(set) var phase: Phase
    @Published private(set) var allowance: Allowance?
    @Published private(set) var plan: PlanInfo?
    @Published private(set) var block: Block?
    /// True while a typed code is being checked with the server.
    @Published private(set) var isChecking = false
    /// Friendly text for the code screen after a failed attempt. Nil otherwise.
    @Published private(set) var codeMessage: String?

    private let store: StudentCodeStoring
    private let holder: StudentCodeHolder
    private let fetchMe: () async throws -> MeResponse
    /// Asks the server for a new free code ("Start free"). Nil when this build has no server to ask (then the button is not shown).
    private let createFreeCode: (() async throws -> FreeCodeResponse)?
    private let log: SessionLog

    /// Called to say an allowance line out loud. Wired to the speech player by `AppEnvironment`.
    var announce: (SpokenNotice) -> Void = { _ in }

    private var lowAnnouncedMonth: String?
    private var usedUpAnnounced = false
    private var problemsOpen = 0
    private var refreshTask: Task<Void, Never>?

    init(
        store: StudentCodeStoring,
        holder: StudentCodeHolder,
        log: SessionLog,
        fetchMe: @escaping () async throws -> MeResponse,
        createFreeCode: (() async throws -> FreeCodeResponse)? = nil
    ) {
        self.store = store
        self.holder = holder
        self.log = log
        self.fetchMe = fetchMe
        self.createFreeCode = createFreeCode
        if let stored = store.load(), StudentCode.isValid(stored) {
            holder.current = stored
            phase = .ready
            log.record("student_code_loaded", ["code_hash": StudentCode.shortHash(stored)])
        } else {
            if store.load() != nil {
                store.clear()
                log.record("student_code_discarded", ["reason": "stored_value_not_a_valid_code"])
            }
            holder.current = nil
            phase = .needsCode
            log.record("student_code_missing", ["next": "code_screen"])
        }
    }

    /// UI tests and builds with no server: no code screen, a healthy allowance, no live voice.
    func startScripted(allowance: Allowance, plan: PlanInfo) {
        phase = .ready
        self.allowance = allowance
        self.plan = plan
        log.record("account_scripted", ["remaining_minutes": allowance.remainingMinutes, "live": plan.live])
    }

    /// A build with no server address: no code screen, nothing to meter. The student can still write.
    func startWithoutServer() {
        phase = .ready
        log.record("account_without_server", ["next": "writing_only"])
    }

    var isBlocked: Bool { block != nil }

    /// `ABCD-••••` for Settings. Nil when there is no code.
    var maskedCode: String? { holder.current.map(StudentCode.masked) }

    /// True when the plan includes live voice. Unknown (the check has not worked yet) counts as no.
    var liveAllowed: Bool { plan?.live == true }

    // MARK: - Signing in and out

    /// Checks a typed code with the server (GET /api/me) and keeps it in the Keychain when it works.
    func signIn(typed: String) async {
        let code = StudentCode.normalize(typed)
        if let problem = StudentCode.problem(with: code) {
            switch problem {
            case "empty", "too_short", "too_long":
                codeMessage = "Your code has 8 letters and numbers. Check it and try again."
            case "characters_not_in_alphabet":
                codeMessage = "Codes never use the letters I, L, O or U, or the numbers 0 and 1. Check your code and try again."
            default:
                codeMessage = AllowanceText.wrongCode
            }
            log.record("code_rejected_locally", ["reason": problem, "typed_chars": code.count])
            return
        }
        isChecking = true
        codeMessage = nil
        let previous = holder.current
        holder.current = code
        let hash = StudentCode.shortHash(code)
        do {
            let me = try await fetchMe()
            do {
                try store.save(code)
                log.record("student_code_saved", ["code_hash": hash])
            } catch {
                // The code works for this launch; it will have to be typed again next time.
                log.record("student_code_save_failed", ["code_hash": hash, "detail": String(describing: error)])
            }
            apply(me: me, reason: "code_entered")
            phase = .ready
            log.record("code_accepted", ["code_hash": hash, "live": me.plan.live, "state": me.allowance.state.rawValue])
        } catch {
            holder.current = previous
            let (student, detail) = TutorError.describe(error)
            codeMessage = student
            log.record("code_refused", ["code_hash": hash, "detail": detail])
        }
        isChecking = false
    }

    /// True when the code screen can offer "Start free" (this build can reach a server).
    var canStartFree: Bool { createFreeCode != nil }

    /// "Start free": asks the server for a new code, keeps it in the Keychain exactly as a typed code is kept, and signs in.
    /// The code is saved and the app opened BEFORE the usual check with the server (`refresh`), so a lost connection right after the
    /// code was made cannot lose it: it behaves like a launch with a stored code. Failures are shown in plain words (the server's
    /// per-address limit and a full month each have their own kind message); nothing technical reaches the student.
    func startFree() async {
        guard let createFreeCode, !isChecking else { return }
        isChecking = true
        codeMessage = nil
        let started = Date()
        log.record("free_code_requested", ["next": "server_makes_a_code"])
        do {
            let made = try await createFreeCode()
            let code = StudentCode.normalize(made.code)
            guard StudentCode.isValid(code) else {
                codeMessage = "Something went wrong. Try again."
                log.record("free_code_bad_shape", ["problem": StudentCode.problem(with: code) ?? "invalid"])
                isChecking = false
                return
            }
            let hash = StudentCode.shortHash(code)
            holder.current = code
            do {
                try store.save(code)
                log.record("student_code_saved", ["code_hash": hash, "origin": "free"])
            } catch {
                // The code works for this launch; the student would have to Start free again next time.
                log.record("student_code_save_failed", ["code_hash": hash, "origin": "free", "detail": String(describing: error)])
            }
            phase = .ready
            log.record("free_code_started", [
                "code_hash": hash, "cap_minutes": made.capMinutes ?? -1,
                "elapsed_ms": Int(Date().timeIntervalSince(started) * 1000)
            ])
            isChecking = false
            await refresh(reason: "free_code_created")
        } catch {
            let (student, detail) = TutorError.describe(error)
            codeMessage = student
            isChecking = false
            log.record("free_code_failed", ["detail": detail, "elapsed_ms": Int(Date().timeIntervalSince(started) * 1000)])
        }
    }

    /// "Use a different code": forgets the code and shows the code screen.
    func signOut(reason: String) {
        let hash = holder.current.map(StudentCode.shortHash) ?? "none"
        store.clear()
        holder.current = nil
        allowance = nil
        plan = nil
        block = nil
        usedUpAnnounced = false
        lowAnnouncedMonth = nil
        codeMessage = nil
        phase = .needsCode
        log.record("student_code_cleared", ["code_hash": hash, "reason": reason])
    }

    // MARK: - Asking the server

    /// GET /api/me: validates the code, learns the plan, wakes the database. Calls made together share one request.
    func refresh(reason: String) async {
        if let running = refreshTask {
            await running.value
            return
        }
        guard holder.current != nil else {
            log.record("me_skipped", ["reason": "no_student_code", "why_asked": reason])
            return
        }
        let task = Task { @MainActor in await self.performRefresh(reason: reason) }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh(reason: String) async {
        let started = Date()
        do {
            let me = try await fetchMe()
            apply(me: me, reason: reason)
            log.record("me_ok", [
                "why_asked": reason, "live": me.plan.live, "cap_minutes": me.plan.capMinutes,
                "remaining_minutes": me.allowance.remainingMinutes, "state": me.allowance.state.rawValue,
                "elapsed_ms": Int(Date().timeIntervalSince(started) * 1000)
            ])
        } catch {
            let (_, detail) = TutorError.describe(error)
            log.record("me_failed", [
                "why_asked": reason, "detail": detail, "elapsed_ms": Int(Date().timeIntervalSince(started) * 1000),
                "plan_now": plan == nil ? "unknown_so_base_plan" : "kept_from_earlier"
            ])
            if let tutorError = error as? TutorError { handle(serverError: tutorError) }
        }
    }

    // MARK: - What the server told us

    private func apply(me: MeResponse, reason: String) {
        plan = me.plan
        applyFree(me.free)
        apply(allowance: me.allowance, source: "me:\(reason)")
    }

    /// For a free code, `me` says whether free tutoring is full this month. It is how the "full" banner clears on the 1st.
    private func applyFree(_ free: FreeInfo?) {
        guard let free else { return }
        if free.full {
            if block != .freeTutoringFull {
                block = .freeTutoringFull
                log.record("block_entered", ["reason": Block.freeTutoringFull.logLabel, "source": "me"])
            }
        } else if block == .freeTutoringFull {
            block = nil
            log.record("block_cleared", ["was": Block.freeTutoringFull.logLabel, "why": "server says free tutoring is open again"])
        }
    }

    /// A fresh allowance from any reply. Decides about the 80% line and the 100% line (`AllowanceDecision`).
    func apply(allowance new: Allowance, source: String) {
        let decision = AllowanceDecision.decide(
            previous: allowance, new: new, lowAnnouncedMonth: lowAnnouncedMonth, currentlyUsedUp: block == .hoursUsedUp
        )
        allowance = new
        var fields: [String: Any] = [
            "source": source, "state": new.state.rawValue, "remaining_minutes": new.remainingMinutes,
            "percent_used": (new.percentUsed * 10).rounded() / 10, "month": new.month
        ]
        if let notice = new.notice { fields["notice"] = notice.rawValue }
        log.record("allowance_updated", fields)

        if decision.enterUsedUp { enterUsedUp() }
        if decision.clearUsedUp {
            block = nil
            usedUpAnnounced = false
            log.record("block_cleared", ["was": Block.hoursUsedUp.logLabel, "why": "server reports hours available again"])
        }
        if let minutes = decision.speakLow {
            lowAnnouncedMonth = new.month
            log.record("allowance_low_announced", ["remaining_minutes": minutes])
            announce(.low(minutes: minutes))
        }
    }

    /// A refusal or failure from the server that concerns the code or the hours. Other errors are not this class's business.
    func handle(serverError error: TutorError) {
        switch error {
        case .unauthorized(let reason):
            let forget = reason == "unknown_code" || reason == "malformed_code"
            log.record("code_rejected_by_server", ["reason": reason, "cleared": forget])
            if forget { store.clear() }
            holder.current = nil
            allowance = nil
            plan = nil
            block = nil
            codeMessage = AllowanceText.wrongCode
            phase = .needsCode
        case .codeTurnedOff:
            if block != .codeTurnedOff {
                block = .codeTurnedOff
                log.record("block_entered", ["reason": Block.codeTurnedOff.logLabel])
            }
        case .hoursUsedUp(let seen):
            if let seen {
                apply(allowance: seen, source: "refusal")
            } else {
                enterUsedUp()
            }
        case .freeTutoringFull:
            if block != .freeTutoringFull {
                block = .freeTutoringFull
                log.record("block_entered", ["reason": Block.freeTutoringFull.logLabel, "source": "refusal"])
            }
        default:
            break
        }
    }

    private func enterUsedUp() {
        if block != .hoursUsedUp {
            block = .hoursUsedUp
            log.record("block_entered", ["reason": Block.hoursUsedUp.logLabel])
        }
        speakUsedUpIfPossible()
    }

    // MARK: - Saying it out loud

    /// The used-up line is said once per app launch, and only while a problem is open (not out of nowhere on the list).
    private func speakUsedUpIfPossible() {
        guard block == .hoursUsedUp else { return }
        guard !usedUpAnnounced else {
            log.record("used_up_announce_skipped", ["reason": "already_said_this_launch"])
            return
        }
        guard problemsOpen > 0 else {
            log.record("used_up_announce_skipped", ["reason": "no_problem_open_yet", "next": "said_when_a_problem_opens"])
            return
        }
        usedUpAnnounced = true
        log.record("used_up_announced", [:])
        announce(.usedUp)
    }

    func problemOpened() {
        problemsOpen += 1
        speakUsedUpIfPossible()
    }

    func problemClosed() {
        problemsOpen = max(0, problemsOpen - 1)
    }
}
