import Foundation

/// Decides when the app should send a heartbeat so the server can count the student's real working time.
///
/// The server counts the gaps between the student's activity moments (ink, a question, the tutor looking, live talk), and a
/// gap longer than 60 seconds counts as zero. Looks and questions already reach the server as requests. Ink and live talk
/// do not, so a heartbeat carries them: every 30 seconds, if there is a moment it has not reported yet, it sends how long ago
/// the latest one was. A heartbeat with nothing new is never sent, so a student who walks away accrues nothing. 30 seconds
/// (not 60) so that steady writing reports a moment well inside the server's 60 second gap, even with a late tick.
/// Never in the background, on the problem list, or when the hours are used up.
///
/// Pure value logic with an injectable clock: callers pass `now`.
struct ActivityMeter {
    static let heartbeatInterval: TimeInterval = 30
    /// Guards against two loops beating at once; the loop itself runs every `heartbeatInterval`.
    static let minimumGap: TimeInterval = 25
    /// Activity older than this is not reported (the app was in the background or the beat kept failing): the server would
    /// count a gap that long as zero anyway.
    static let staleAfter: TimeInterval = 300

    enum Kind: String {
        case ink
        case question
        case look
        case speech
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
        case noNewActivity = "skip_no_new_activity"
        case staleActivity = "skip_activity_older_than_5_min"
        case tooSoon = "skip_sent_less_than_25s_ago"
    }

    private var lastActivity: (kind: Kind, at: Date)?
    private var lastHeartbeatAt: Date?
    /// The latest activity moment a heartbeat has already carried, and the one before it (to undo a failed send).
    private var reportedActivityAt: Date?
    private var reportedBeforeLastSend: Date?

    /// Records an activity moment. Only the latest one is kept; an older one arriving late is ignored.
    mutating func note(_ kind: Kind, at: Date) {
        if let lastActivity, lastActivity.at > at { return }
        lastActivity = (kind, at)
    }

    /// Call when a heartbeat is sent: the activity it carries counts as reported.
    mutating func noteHeartbeatSent(at: Date) {
        lastHeartbeatAt = at
        reportedBeforeLastSend = reportedActivityAt
        reportedActivityAt = lastActivity?.at
    }

    /// Call when the send failed: the same activity is reported again on the next beat.
    mutating func noteHeartbeatFailed() {
        reportedActivityAt = reportedBeforeLastSend
    }

    func decide(now: Date, problemOpen: Bool, inForeground: Bool, blocked: Bool) -> Decision {
        guard problemOpen else { return .skip(reason: .problemClosed) }
        guard inForeground else { return .skip(reason: .background) }
        guard !blocked else { return .skip(reason: .blocked) }
        guard let lastActivity, lastActivity.at > (reportedActivityAt ?? .distantPast) else {
            return .skip(reason: .noNewActivity)
        }
        let age = now.timeIntervalSince(lastActivity.at)
        guard age <= Self.staleAfter else { return .skip(reason: .staleActivity) }
        if let lastHeartbeatAt, now.timeIntervalSince(lastHeartbeatAt) < Self.minimumGap {
            return .skip(reason: .tooSoon)
        }
        return .send(lastActivity: lastActivity.kind, secondsAgo: max(0, Int(age)))
    }
}
