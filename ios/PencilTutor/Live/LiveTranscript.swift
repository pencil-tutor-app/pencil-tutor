import Foundation

/// Who is speaking in the live conversation.
enum LiveSpeaker: String, Equatable {
    case student
    case tutor
}

/// One stretch of speech by one person.
struct LiveTurn: Equatable {
    var speaker: LiveSpeaker
    var text: String
}

/// Groups the session's transcript fragments into turns and remembers the last few.
///
/// OpenAI sends transcript text as small fragments with no "turn finished" event (guides/live-conversations, "Transcript
/// deltas"), so a turn here is simply: fragments from one speaker with less than `gap` seconds between them. That is a
/// grouping for the log and for follow-up questions, not a guarantee about who finished speaking. It is bounded: at most
/// `keep` turns and `maxTurnCharacters` per turn.
///
/// Time comes in as an argument so tests do not wait.
struct LiveTranscript {
    static let gap: TimeInterval = 1.6
    static let keep = 12
    static let maxTurnCharacters = 600

    private(set) var turns: [LiveTurn] = []
    private var open: [LiveSpeaker: (text: String, lastAt: Date)] = [:]
    /// Student turns that finished or are still open since the last question was taken for a delegation.
    private var unaskedStudentTurns: [String] = []
    /// True once the still-open student turn has already been handed out as a question, so closing it does not count it twice.
    private var openStudentTurnWasAsked = false

    /// Adds a fragment. Returns any turn this fragment finished (a turn by the same speaker that went quiet).
    @discardableResult
    mutating func add(_ speaker: LiveSpeaker, fragment: String, at now: Date) -> [LiveTurn] {
        guard !fragment.isEmpty else { return [] }
        var finished: [LiveTurn] = []
        if let current = open[speaker], now.timeIntervalSince(current.lastAt) >= Self.gap {
            finished.append(close(speaker))
        }
        let existing = open[speaker]?.text ?? ""
        open[speaker] = (Self.clip(existing + fragment), now)
        return finished
    }

    /// Finishes every turn that has been quiet for `gap`. Call it on a timer.
    @discardableResult
    mutating func finishQuiet(at now: Date) -> [LiveTurn] {
        var finished: [LiveTurn] = []
        for speaker in [LiveSpeaker.student, .tutor] {
            if let current = open[speaker], now.timeIntervalSince(current.lastAt) >= Self.gap {
                finished.append(close(speaker))
            }
        }
        return finished
    }

    /// Finishes everything now (the session is ending).
    @discardableResult
    mutating func finishAll() -> [LiveTurn] {
        [LiveSpeaker.student, .tutor].compactMap { open[$0] == nil ? nil : close($0) }
    }

    /// What the student said since the last delegation took its question, including a turn still being spoken. If they said
    /// nothing new, the last thing they said (so "check again" still has a question). Empty only if they never spoke.
    mutating func takeQuestion(maxCharacters: Int = 600) -> String {
        var parts = unaskedStudentTurns
        if !openStudentTurnWasAsked, let spoken = open[.student]?.text, !spoken.isEmpty {
            parts.append(spoken)
            openStudentTurnWasAsked = true
        }
        unaskedStudentTurns = []
        if parts.isEmpty {
            parts = [turns.last(where: { $0.speaker == .student })?.text].compactMap { $0 }
        }
        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.count <= maxCharacters ? joined : String(joined.suffix(maxCharacters))
    }

    /// The last few turns, oldest first, shaped for a consult request. Open turns are included.
    func recent(limit: Int = 6, maxCharactersPerTurn: Int = 240) -> [ConsultTurnWire] {
        var all = turns
        for speaker in [LiveSpeaker.student, .tutor] {
            if let current = open[speaker] { all.append(LiveTurn(speaker: speaker, text: current.text)) }
        }
        return all.suffix(limit).map { turn in
            ConsultTurnWire(role: turn.speaker.rawValue, text: String(turn.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxCharactersPerTurn)))
        }.filter { !$0.text.isEmpty }
    }

    private mutating func close(_ speaker: LiveSpeaker) -> LiveTurn {
        let text = (open[speaker]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        open[speaker] = nil
        let turn = LiveTurn(speaker: speaker, text: text)
        if !text.isEmpty {
            turns.append(turn)
            if turns.count > Self.keep { turns.removeFirst(turns.count - Self.keep) }
            if speaker == .student, !openStudentTurnWasAsked { unaskedStudentTurns.append(text) }
        }
        if speaker == .student { openStudentTurnWasAsked = false }
        return turn
    }

    private static func clip(_ text: String) -> String {
        text.count <= maxTurnCharacters ? text : String(text.suffix(maxTurnCharacters))
    }
}
