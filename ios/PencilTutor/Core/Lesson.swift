import Foundation

/// One turn of the lesson conversation.
struct LessonTurn: Identifiable, Equatable {
    enum Role: String { case student, tutor }
    let id = UUID()
    let role: Role
    let text: String
}

/// What the explain call returned, ready to draw. The example is kept apart: the panel is only ever handed it once the server's
/// check has accepted it (`LessonSession.visibleExample`).
struct Lesson: Equatable {
    let title: String
    let steps: [String]
    let example: TeachExample
    let spoken: String?

    /// A lesson needs a title, at least one step and an example; anything else is a failed call, never a half-drawn panel.
    init?(_ response: TeachExplainResponse) {
        guard let sent = response.lesson else { return nil }
        let title = sent.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let steps = sent.steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !title.isEmpty, !steps.isEmpty, !sent.example.promptPlain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.title = title
        self.steps = steps
        self.example = sent.example
        self.spoken = sent.spoken?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Number of worked lines in the example (statement, steps, answer), for the log.
    var exampleLines: Int { example.steps.count + 2 }

    /// The lesson as plain text for the server, at most `LessonText.maxCharacters`. The example goes in only when `includeExample`
    /// (its check passed), so the follow-up model never talks about an unchecked example.
    func text(includeExample: Bool) -> String {
        var lines = [title]
        for (index, step) in steps.enumerated() { lines.append("\(index + 1). \(step)") }
        if includeExample {
            lines.append("Example: \(example.promptPlain)")
            lines.append(contentsOf: example.steps)
            lines.append("Answer: \(example.finalAnswer)")
        }
        return LessonText.fit(lines)
    }
}

enum LessonText {
    /// What the server accepts for `lesson_text`.
    static let maxCharacters = 3_000

    /// Whole lines while they fit; a single line longer than the limit is cut at the limit (the server would refuse it otherwise).
    static func fit(_ lines: [String]) -> String {
        var kept: [String] = []
        var used = 0
        for line in lines {
            let cost = line.count + (kept.isEmpty ? 0 : 1)
            if used + cost > maxCharacters { break }
            kept.append(line)
            used += cost
        }
        if kept.isEmpty, let first = lines.first { return String(first.prefix(maxCharacters)) }
        return kept.joined(separator: "\n")
    }
}

/// The conversation memory sent with each question: the last 8 turns, each at most 400 characters, oldest first.
enum LessonRecent {
    static let maxTurns = 8
    static let maxCharacters = 400

    static func wire(_ turns: [LessonTurn]) -> [ConsultTurnWire] {
        turns.suffix(maxTurns).map { ConsultTurnWire(role: $0.role.rawValue, text: String($0.text.prefix(maxCharacters))) }
    }
}
