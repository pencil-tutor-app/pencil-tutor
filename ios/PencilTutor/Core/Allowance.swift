import Foundation

// The monthly allowance as the server reports it (contract 2026-11-14). The server counts the minutes; the app only shows
// them and reacts to the 80% and 100% marks.

enum AllowanceState: String, Codable, Equatable {
    case ok
    case low
    case usedUp = "used_up"

    /// An unknown word from a newer server is treated as "ok" rather than failing the whole reply.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AllowanceState(rawValue: raw) ?? .ok
    }
}

enum AllowanceNotice: String, Codable, Equatable {
    case low
    case usedUp = "used_up"

    /// An unknown notice word is ignored (decoded as nil by `Allowance`), never spoken.
    init?(wire: String?) {
        guard let wire else { return nil }
        self.init(rawValue: wire)
    }
}

struct Allowance: Codable, Equatable {
    var month: String
    var usedSeconds: Int
    var capSeconds: Int
    var remainingSeconds: Int
    var remainingMinutes: Int
    var percentUsed: Double
    var state: AllowanceState
    /// Non-nil on exactly one response per month for each threshold.
    var notice: AllowanceNotice?

    private enum CodingKeys: String, CodingKey {
        case month, state, notice
        case usedSeconds = "used_seconds"
        case capSeconds = "cap_seconds"
        case remainingSeconds = "remaining_seconds"
        case remainingMinutes = "remaining_minutes"
        case percentUsed = "percent_used"
    }

    init(month: String, usedSeconds: Int, capSeconds: Int, remainingSeconds: Int, remainingMinutes: Int,
         percentUsed: Double, state: AllowanceState, notice: AllowanceNotice? = nil) {
        self.month = month
        self.usedSeconds = usedSeconds
        self.capSeconds = capSeconds
        self.remainingSeconds = remainingSeconds
        self.remainingMinutes = remainingMinutes
        self.percentUsed = percentUsed
        self.state = state
        self.notice = notice
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        month = try c.decode(String.self, forKey: .month)
        usedSeconds = try c.decode(Int.self, forKey: .usedSeconds)
        capSeconds = try c.decode(Int.self, forKey: .capSeconds)
        remainingSeconds = try c.decode(Int.self, forKey: .remainingSeconds)
        remainingMinutes = try c.decode(Int.self, forKey: .remainingMinutes)
        percentUsed = try c.decode(Double.self, forKey: .percentUsed)
        state = try c.decode(AllowanceState.self, forKey: .state)
        notice = AllowanceNotice(wire: try c.decodeIfPresent(String.self, forKey: .notice))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(month, forKey: .month)
        try c.encode(usedSeconds, forKey: .usedSeconds)
        try c.encode(capSeconds, forKey: .capSeconds)
        try c.encode(remainingSeconds, forKey: .remainingSeconds)
        try c.encode(remainingMinutes, forKey: .remainingMinutes)
        try c.encode(percentUsed, forKey: .percentUsed)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(notice?.rawValue, forKey: .notice)
    }

    /// What the problem screen and Settings show. Plain words.
    var chipText: String {
        state == .usedUp ? "Hours used up" : "\(remainingMinutes) min left"
    }
}

struct PlanInfo: Codable, Equatable {
    var live: Bool
    var capMinutes: Int

    private enum CodingKeys: String, CodingKey {
        case live
        case capMinutes = "cap_minutes"
    }
}

/// GET /api/me
struct MeResponse: Codable, Equatable {
    var plan: PlanInfo
    var allowance: Allowance
    var requestId: String?
    /// Present only for a free code ("Start free"): whether all free codes together have used this month's allowance of money.
    /// Absent for a code Edward made by hand, and from an older server.
    var free: FreeInfo? = nil

    private enum CodingKeys: String, CodingKey {
        case plan, allowance, free
        case requestId = "request_id"
    }
}

struct FreeInfo: Codable, Equatable {
    var full: Bool
}

/// POST /api/free-code ("Start free"): the server makes a new code. The request carries no bearer, because there is no code yet.
struct FreeCodeResponse: Codable, Equatable {
    var code: String
    var capMinutes: Int?
    var requestId: String?

    private enum CodingKeys: String, CodingKey {
        case code
        case capMinutes = "cap_minutes"
        case requestId = "request_id"
    }
}

/// POST /api/heartbeat
struct HeartbeatRequest: Codable, Equatable {
    var sessionId: String
    var problemId: String
    /// How long ago the student's last real activity (ink, a question, a look, live talk) was, by this device's own clock.
    /// The server counts time only from this; a heartbeat without it counts nothing.
    var secondsSinceActivity: Int? = nil

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case problemId = "problem_id"
        case secondsSinceActivity = "seconds_since_activity"
    }
}

struct HeartbeatResponse: Codable, Equatable {
    var ok: Bool
    var allowance: Allowance
    var requestId: String?

    private enum CodingKeys: String, CodingKey {
        case ok, allowance
        case requestId = "request_id"
    }
}

/// A line the tutor says about the allowance. The server composes the audio; the text here is the device-voice fallback.
enum SpokenNotice: Equatable {
    case low(minutes: Int)
    case usedUp

    /// The `purpose` label sent to /api/speak (no text is sent for these two).
    var purpose: String {
        switch self {
        case .low: return "allowance_low"
        case .usedUp: return "allowance_used_up"
        }
    }

    var fallbackText: String {
        switch self {
        case .low(let minutes):
            return minutes == 1 ? "You have about 1 minute left this month." : "You have about \(minutes) minutes left this month."
        case .usedUp:
            return AllowanceText.usedUp
        }
    }
}

enum AllowanceText {
    static let usedUp = "This month's tutoring hours are used up. They start fresh on the 1st."
    static let codeTurnedOff = "This code has been turned off. Ask Edward."
    static let wrongCode = "That code did not work. Check it and try again."
    /// All free codes together have used this month's money. Shown kindly; it comes back on the 1st (Vancouver time).
    static let freeTutoringFull = "Free tutoring is full this month, it comes back on the 1st."
    /// Too many free codes were made from this network today (the server's per-address limit).
    static let freeCodeLimit = "A few free codes have already been made on this network today. Try again tomorrow, or type a code if you have one."
}

/// What the app should do about a newly arrived allowance. Pure, so the 80% and 100% rules are tested without a screen.
struct AllowanceDecision: Equatable {
    var speakLow: Int?          // minutes left to say, when the 80% line was just crossed
    var enterUsedUp = false
    var clearUsedUp = false

    /// - lowAnnouncedMonth: the month for which the app already said the 80% line this launch.
    static func decide(previous: Allowance?, new: Allowance, lowAnnouncedMonth: String?, currentlyUsedUp: Bool) -> AllowanceDecision {
        var decision = AllowanceDecision()
        if new.notice == .low, lowAnnouncedMonth != new.month, new.state != .usedUp {
            decision.speakLow = new.remainingMinutes
        }
        if new.notice == .usedUp || new.state == .usedUp {
            decision.enterUsedUp = true
        } else if currentlyUsedUp {
            // A new month, or Edward topped it up: the hours are back.
            decision.clearUsedUp = true
        }
        return decision
    }
}
