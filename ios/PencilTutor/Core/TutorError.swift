import Foundation

/// Everything that can go wrong between the student's pencil and the tutor's answer.
/// `studentMessage` is short, plain and safe to show. `logDetail` is for the on-device log only.
enum TutorError: Error {
    case notConfigured(reason: String)
    case offline(detail: String)
    case timedOut
    /// HTTP 401: the code is missing or wrong. `reason` is the server's label (`unknown_code`, `malformed_code`, ...).
    case unauthorized(reason: String)
    /// HTTP 403 `code_disabled`.
    case codeTurnedOff
    /// HTTP 403 `hours_used_up`. Carries the allowance the server sent with it, when there was one.
    case hoursUsedUp(allowance: Allowance?)
    /// HTTP 403 `live_not_in_plan` (from /api/live-session only).
    case liveNotInPlan
    /// HTTP 403 `free_tutoring_full`: all free codes together have used this month's money. Also the refusal of "Start free".
    case freeTutoringFull
    /// HTTP 429 `rate_limited`: this network has made its free codes for the day ("Start free" only).
    case freeCodeLimit
    case rejected(status: Int, reason: String)
    case serverUnavailable(status: Int, reason: String)
    case badResponse(detail: String)
    case snapshotFailed(detail: String)
    case microphoneDenied
    case recordingTooShort
    case recordingFailed(detail: String)
    case problemBankMissing

    var studentMessage: String {
        switch self {
        case .notConfigured:
            return "The tutor is not connected yet. You can still write your work."
        case .offline:
            return "I can't reach the tutor. Check the internet and try again."
        case .timedOut:
            return "The tutor is taking too long. Try again in a moment."
        case .unauthorized:
            return AllowanceText.wrongCode
        case .codeTurnedOff:
            return AllowanceText.codeTurnedOff
        case .hoursUsedUp:
            return AllowanceText.usedUp
        case .liveNotInPlan:
            return "Voice chat isn't part of this plan. You can still tap the microphone to ask a question."
        case .freeTutoringFull:
            return AllowanceText.freeTutoringFull
        case .freeCodeLimit:
            return AllowanceText.freeCodeLimit
        case .rejected:
            return "The tutor couldn't read that. Try again."
        case .serverUnavailable:
            return "The tutor is resting right now. Try again in a little while."
        case .badResponse:
            return "The tutor sent something I couldn't understand. Try again."
        case .snapshotFailed:
            return "I couldn't look at your page. Try again."
        case .microphoneDenied:
            return "I need the microphone to hear you. Turn it on in Settings."
        case .recordingTooShort:
            return "I didn't catch that. Tap the microphone, ask your question, then tap it again."
        case .recordingFailed:
            return "I couldn't record that. Try again."
        case .problemBankMissing:
            return "The problems didn't load. Please tell your teacher."
        }
    }

    /// Full detail for the session log. Never contains keys, codes or tokens.
    var logDetail: String {
        switch self {
        case .notConfigured(let reason): return "not_configured: \(reason)"
        case .offline(let detail): return "offline: \(detail)"
        case .timedOut: return "timed_out"
        case .unauthorized(let reason): return "unauthorized (HTTP 401): \(reason)"
        case .codeTurnedOff: return "code_disabled (HTTP 403)"
        case .hoursUsedUp: return "hours_used_up (HTTP 403)"
        case .liveNotInPlan: return "live_not_in_plan (HTTP 403)"
        case .freeTutoringFull: return "free_tutoring_full (HTTP 403)"
        case .freeCodeLimit: return "free_code_limit (HTTP 429)"
        case .rejected(let status, let reason): return "rejected HTTP \(status): \(reason)"
        case .serverUnavailable(let status, let reason): return "server_unavailable HTTP \(status): \(reason)"
        case .badResponse(let detail): return "bad_response: \(detail)"
        case .snapshotFailed(let detail): return "snapshot_failed: \(detail)"
        case .microphoneDenied: return "microphone_denied"
        case .recordingTooShort: return "recording_too_short"
        case .recordingFailed(let detail): return "recording_failed: \(detail)"
        case .problemBankMissing: return "problem_bank_missing_or_empty"
        }
    }

    static func describe(_ error: Error) -> (student: String, detail: String) {
        if let tutorError = error as? TutorError {
            return (tutorError.studentMessage, tutorError.logDetail)
        }
        return ("Something went wrong. Try again.", "unexpected: \(String(describing: error))")
    }
}
