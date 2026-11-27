import Foundation

// "Learn something new": the requests and replies of POST /api/teach (docs/teach-mode-plan.md, Revision 2). One endpoint, three
// actions. Field names on the wire are snake_case, written out explicitly. Every maths line is plain text in the notation
// `MathMarkup` already reads, so what is shown is what was checked.

/// The worked example of a lesson. The app shows it only after the server's two-call check has accepted it (`LessonSession`).
struct TeachExample: Codable, Equatable {
    var promptPlain: String
    var steps: [String]
    var finalAnswer: String

    private enum CodingKeys: String, CodingKey {
        case promptPlain = "prompt_plain"
        case steps
        case finalAnswer = "final_answer"
    }
}

/// The lesson as the server writes it and as the practice call hands it back: a title, at most 4 steps and one worked example.
struct TeachLesson: Codable, Equatable {
    var title: String
    var steps: [String]
    var example: TeachExample
    /// At most two sentences, said aloud when the panel appears. Not sent back with a practice request.
    var spoken: String? = nil
}

struct TeachExplainRequest: Codable, Equatable {
    var action = "explain"
    var sessionId: String
    var course: String
    var concept: String

    private enum CodingKeys: String, CodingKey {
        case action, course, concept
        case sessionId = "session_id"
    }
}

/// The reply to `explain`, flat as the server writes it (`server/lib/teach.ts`): `is_math`, `fits_course`, `message`, then `title`,
/// `steps`, `example` and `spoken`, which are all present and null when there is no lesson (not maths, or another course).
/// `lesson` is built from the flat fields when title, steps and example are all there.
struct TeachExplainResponse: Equatable {
    /// False when the concept is not a maths topic.
    var isMath: Bool
    /// False when it is maths but belongs to another course. A server that does not say counts as true.
    var fitsCourse: Bool?
    /// The words to show when there is no lesson ("I can teach maths topics only.").
    var message: String?
    /// Nil when the concept is refused or a lesson field is missing.
    var lesson: TeachLesson?
    var requestId: String?
    var model: String?
    var latencyMs: Int?
    var allowance: Allowance? = nil

    private enum CodingKeys: String, CodingKey {
        case message, title, steps, example, spoken, model, allowance
        case isMath = "is_math"
        case fitsCourse = "fits_course"
        case requestId = "request_id"
        case latencyMs = "latency_ms"
    }
}

extension TeachExplainResponse: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isMath = try container.decode(Bool.self, forKey: .isMath)
        fitsCourse = try container.decodeIfPresent(Bool.self, forKey: .fitsCourse)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        latencyMs = try container.decodeIfPresent(Int.self, forKey: .latencyMs)
        allowance = try container.decodeIfPresent(Allowance.self, forKey: .allowance)
        let title = try container.decodeIfPresent(String.self, forKey: .title)
        let steps = try container.decodeIfPresent([String].self, forKey: .steps)
        let example = try container.decodeIfPresent(TeachExample.self, forKey: .example)
        let spoken = try container.decodeIfPresent(String.self, forKey: .spoken)
        if let title, let steps, let example {
            lesson = TeachLesson(title: title, steps: steps, example: example, spoken: spoken)
        } else {
            lesson = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isMath, forKey: .isMath)
        try container.encodeIfPresent(fitsCourse, forKey: .fitsCourse)
        try container.encode(message, forKey: .message)
        try container.encode(lesson?.title, forKey: .title)
        try container.encode(lesson?.steps, forKey: .steps)
        try container.encode(lesson?.example, forKey: .example)
        try container.encode(lesson?.spoken, forKey: .spoken)
        try container.encodeIfPresent(requestId, forKey: .requestId)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(latencyMs, forKey: .latencyMs)
        try container.encodeIfPresent(allowance, forKey: .allowance)
    }
}

struct TeachFollowupRequest: Codable, Equatable {
    var action = "followup"
    var sessionId: String
    var course: String
    var concept: String
    /// The lesson as text, at most 3,000 characters. The example is in it only once its check has passed.
    var lessonText: String
    /// The last 8 turns, each at most 400 characters.
    var recent: [ConsultTurnWire]
    /// A typed question, or `audioBase64` for a spoken one (exactly one of the two).
    var question: String? = nil
    var audioBase64: String? = nil
    /// Set once a practice problem exists, so an answer that would give its final answer is withheld. The server opens the
    /// reference against `problemText`, the same statement, so the two travel together.
    var problemText: String? = nil
    var problemRef: String? = nil
    var attempted: Bool? = nil

    private enum CodingKeys: String, CodingKey {
        case action, course, concept, recent, question, attempted
        case sessionId = "session_id"
        case lessonText = "lesson_text"
        case audioBase64 = "audio_base64"
        case problemText = "problem_text"
        case problemRef = "problem_ref"
    }
}

struct TeachFollowupResponse: Codable, Equatable {
    var transcript: String?
    var answerText: String
    var requestId: String?
    var model: String?
    var latencyMs: Int?
    var allowance: Allowance? = nil

    private enum CodingKeys: String, CodingKey {
        case transcript, model, allowance
        case answerText = "answer_text"
        case requestId = "request_id"
        case latencyMs = "latency_ms"
    }
}

struct TeachPracticeRequest: Codable, Equatable {
    var action = "practice"
    var sessionId: String
    var course: String
    var concept: String
    /// The lesson the student read, as text (at most 3,000 characters), without the example.
    var lessonText: String
    /// The lesson's example, checked by the same two-call path in parallel with the practice problem. Left out when there is none
    /// (then the server does not check it and answers `example_checked: false`).
    var example: TeachExample?

    private enum CodingKeys: String, CodingKey {
        case action, course, concept, example
        case sessionId = "session_id"
        case lessonText = "lesson_text"
    }
}

/// The practice problem: the statement only. Its solution and answer stay on the server inside the sealed reference.
struct TeachPracticeProblem: Codable, Equatable {
    var id: String?
    var promptPlain: String

    private enum CodingKeys: String, CodingKey {
        case id
        case promptPlain = "prompt_plain"
    }
}

struct TeachPracticeResponse: Codable, Equatable {
    /// Nil with `reason: "not_checked"` when the two-call check did not accept a problem. The app never shows an unchecked one.
    var problem: TeachPracticeProblem?
    var reason: String?
    var problemRef: String?
    /// True only when the example passed its check. Missing or false keeps the example out of sight.
    var exampleChecked: Bool?
    var requestId: String?
    var model: String?
    var latencyMs: Int?
    var allowance: Allowance? = nil

    private enum CodingKeys: String, CodingKey {
        case problem, reason, model, allowance
        case problemRef = "problem_ref"
        case exampleChecked = "example_checked"
        case requestId = "request_id"
        case latencyMs = "latency_ms"
    }
}
