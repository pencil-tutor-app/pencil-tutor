import Foundation

/// Everything that can go wrong between the student's pencil and the tutor's answer.
/// `studentMessage` is short, plain and safe to show. `logDetail` is for the on-device log only.
enum TutorError: Error {
    case notConfigured(reason: String)
    case offline(detail: String)
    case timedOut
    case unauthorized
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
            return "The tutor didn't let this app in. Please tell your teacher."
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
            return "Hold the button a little longer while you talk."
        case .recordingFailed:
            return "I couldn't record that. Try again."
        case .problemBankMissing:
            return "The problems didn't load. Please tell your teacher."
        }
    }

    /// Full detail for the session log. Never contains keys or tokens.
    var logDetail: String {
        switch self {
        case .notConfigured(let reason): return "not_configured: \(reason)"
        case .offline(let detail): return "offline: \(detail)"
        case .timedOut: return "timed_out"
        case .unauthorized: return "unauthorized (HTTP 401)"
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
