import Foundation

/// Decides when the app should send a heartbeat so the server can count the minutes.
///
/// The server counts "a minute with a problem open and recent activity (ink, a question or a look within the last 2
/// minutes)". Looks and questions already reach the server as requests. This covers the time between them: while the
/// student keeps writing, a heartbeat every 60 seconds keeps the clock running. Never in the background, on the problem
/// list, or when nothing has happened for two minutes.
///
/// Pure value logic with an injectable clock: callers pass `now`.
struct ActivityMeter {
    /// "Recent" means within this long (the server's window as well).
    static let activityWindow: TimeInterval = 120
    static let heartbeatInterval: TimeInterval = 60
    /// Guards against two loops beating at once; the loop itself runs every `heartbeatInterval`.
    static let minimumGap: TimeInterval = 50

    enum Kind: String {
        case ink
        case question
        case look
    }

    enum Decision: Equatable {
        case send(lastActivity: Kind, secondsAgo: Int)
        case skip(reason: SkipReason)

        var label: String {
            switch self {
            case .send(let kind, _): return "send_after_\(kind.rawValue)"
            case .skip(let reason): return reason.rawValue
            }
        }
    }

    enum SkipReason: String, Equatable {
        case problemClosed = "skip_problem_closed"
        case background = "skip_background"
        case blocked = "skip_hours_used_up_or_code_off"
        case noRecentActivity = "skip_no_activity_in_2_min"
        case tooSoon = "skip_sent_less_than_50s_ago"
    }

    private var lastActivity: (kind: Kind, at: Date)?
    private var lastHeartbeatAt: Date?

    mutating func note(_ kind: Kind, at: Date) {
        lastActivity = (kind, at)
    }

    mutating func noteHeartbeatSent(at: Date) {
        lastHeartbeatAt = at
    }

    func decide(now: Date, problemOpen: Bool, inForeground: Bool, blocked: Bool) -> Decision {
        guard problemOpen else { return .skip(reason: .problemClosed) }
        guard inForeground else { return .skip(reason: .background) }
        guard !blocked else { return .skip(reason: .blocked) }
        guard let lastActivity, now.timeIntervalSince(lastActivity.at) <= Self.activityWindow else {
            return .skip(reason: .noRecentActivity)
        }
        if let lastHeartbeatAt, now.timeIntervalSince(lastHeartbeatAt) < Self.minimumGap {
            return .skip(reason: .tooSoon)
        }
        return .send(lastActivity: lastActivity.kind, secondsAgo: Int(now.timeIntervalSince(lastActivity.at)))
    }
}
