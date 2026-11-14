import Combine
import Foundation

/// The student-side state of the opt-in tutor memory: what the server offers, whether a parent or adult student has agreed, and the
/// actions (turn on, turn off, erase). Everything the server says about consent is shown as it is; the app decides nothing about
/// whether memory is on. Logging rule: labels and counts only, never the notes or the code.
@MainActor
final class MemoryStore: ObservableObject {
    @Published private(set) var status: MemoryStatusResponse?
    /// True while a turn on, turn off or erase is in flight.
    @Published private(set) var busy = false
    /// A calm line for the screen after something did not work. Nil otherwise.
    @Published private(set) var message: String?

    private let api: MemoryAPI
    private let log: SessionLog
    private let codeHash: () -> String?
    private let defaults: UserDefaults
    private var refreshing = false

    init(api: MemoryAPI, log: SessionLog, codeHash: @escaping () -> String?, defaults: UserDefaults = .standard) {
        self.api = api
        self.log = log
        self.codeHash = codeHash
        self.defaults = defaults
    }

    // MARK: - What the screens read

    /// The server offers memory (new agreements are accepted).
    var feature: Bool { status?.feature == "on" }

    /// Something is on record for this code (an agreement, a withdrawal, notes or practice rows), so it can be managed
    /// even when the server has stopped offering memory to anyone new.
    var hasRecord: Bool {
        guard let status else { return false }
        return status.consent != nil || (status.record?.notes ?? 0) > 0 || !(status.record?.recent.isEmpty ?? true)
    }

    /// Whether Settings shows the Memory section at all. A server that says nothing (older server) or offers nothing hides it.
    var isAvailable: Bool { status != nil && (feature || hasRecord) }

    /// Memory is working: the latest agreement is a grant of the text the server offers now.
    var isOn: Bool { status?.consent?.current == true }

    var canTurnOn: Bool { feature && status?.notice != nil }

    /// "On since Nov 14, 2026", "Off", or why it is off.
    var statusLine: String {
        guard let consent = status?.consent else { return "Off" }
        if consent.current { return "On since \(Self.dayText(consent.at))" }
        if consent.granted { return "Off (the text changed, so it needs your agreement again)" }
        return "Off"
    }

    /// Who agreed and how, in plain words, for the record screen.
    var agreementLine: String? {
        guard let consent = status?.consent, consent.current else { return nil }
        let who = consent.givenBy == "adult_student" ? "the adult student" : "a parent or legal guardian"
        let how = consent.recordedVia == "admin" ? "on a signed form that Edward recorded" : "in this app"
        return "Agreed by \(who) \(how) on \(Self.dayText(consent.at))."
    }

    static func dayText(_ iso: String) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = fractional.date(from: iso) ?? plain.date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - Asking the server

    func refresh(reason: String) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let reply = try await api.memoryStatus()
            status = reply
            log.record("memory_status", [
                "why_asked": reason, "feature": reply.feature,
                "consent": reply.consent.map { $0.current ? "current" : ($0.granted ? "old_text" : "withdrawn") } ?? "none",
                "notes": reply.record?.notes ?? 0, "recent": reply.record?.recent.count ?? 0
            ])
        } catch {
            let (_, detail) = TutorError.describe(error)
            if Self.meansUnavailable(error) {
                status = nil
                log.record("memory_unavailable", ["why_asked": reason, "detail": detail])
            } else {
                // A passing network problem keeps what was shown before.
                log.record("memory_status_failed", ["why_asked": reason, "detail": detail])
            }
        }
    }

    /// A server without memory (404) or a build with no server: show nothing rather than an error.
    static func meansUnavailable(_ error: Error) -> Bool {
        guard let tutorError = error as? TutorError else { return false }
        switch tutorError {
        case .notConfigured: return true
        case .rejected(let status, _): return status == 404
        default: return false
        }
    }

    /// Records the agreement. Returns true when memory is on afterwards.
    @discardableResult
    func turnOn(as who: MemoryAttestation) async -> Bool {
        guard let version = status?.notice?.version else { return false }
        busy = true
        message = nil
        defer { busy = false }
        do {
            _ = try await api.memoryAct(.consent(who, version: version))
            log.record("memory_consent_sent", ["given_by": who.rawValue, "notice_version": version])
            await refresh(reason: "after_consent")
            return isOn
        } catch {
            if case TutorError.rejected(409, _)? = error as? TutorError {
                message = "The text changed while you were reading it. Please read it again, then choose."
                log.record("memory_consent_refused", ["reason": "notice_outdated"])
                await refresh(reason: "notice_outdated")
            } else {
                message = Self.friendly(error)
                log.record("memory_consent_failed", ["detail": TutorError.describe(error).detail])
            }
            return false
        }
    }

    /// Turns memory off and, if asked, erases what is stored in the same step.
    @discardableResult
    func turnOff(erase: Bool) async -> Bool {
        await act(.withdraw(erase: erase), event: "memory_withdraw", fields: ["erase": erase])
    }

    @discardableResult
    func erase() async -> Bool {
        await act(.erase, event: "memory_erase", fields: [:])
    }

    private func act(_ request: MemoryActionRequest, event: String, fields: [String: Any]) async -> Bool {
        busy = true
        message = nil
        defer { busy = false }
        do {
            let reply = try await api.memoryAct(request)
            var logged = fields
            logged["attempts_deleted"] = reply.deleted?.attempts ?? 0
            logged["notes_deleted"] = reply.deleted?.notes ?? 0
            log.record(event, logged)
            await refresh(reason: "after_\(request.action)")
            return true
        } catch {
            message = Self.friendly(error)
            log.record("\(event)_failed", ["detail": TutorError.describe(error).detail])
            return false
        }
    }

    static func friendly(_ error: Error) -> String {
        "That did not go through. \(TutorError.describe(error).student)"
    }

    // MARK: - Offered once

    private var offeredKey: String? {
        guard let hash = codeHash(), let version = status?.notice?.version else { return nil }
        return "memory.offered.\(hash).\(version)"
    }

    /// Whether to show the consent screen by itself, once: memory is offered, there is no decision on record for this text (or the
    /// agreement is to an older text), and this code has not been shown this text before. Skipping it counts as having seen it.
    var shouldOffer: Bool {
        if LaunchOptions.scriptedClient && !LaunchOptions.offerMemory { return false }
        guard feature, status?.notice != nil, let key = offeredKey else { return false }
        if let consent = status?.consent, !(consent.granted && !consent.current) { return false }
        return !defaults.bool(forKey: key)
    }

    func markOffered() {
        guard let key = offeredKey else { return }
        defaults.set(true, forKey: key)
        log.record("memory_offer_seen", ["notice_version": status?.notice?.version ?? "?"])
    }
}
