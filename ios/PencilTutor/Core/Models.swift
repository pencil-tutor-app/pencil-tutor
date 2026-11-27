import Foundation

/// One piece of a problem prompt, drawn left to right.
enum PromptPart: Hashable, Codable {
    case text(String)
    case fraction(numerator: String, denominator: String)

    private enum Keys: String, CodingKey { case text, frac }
    private enum FractionKeys: String, CodingKey { case num, den }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(text)
            return
        }
        if container.contains(.frac) {
            let inner = try container.nestedContainer(keyedBy: FractionKeys.self, forKey: .frac)
            let numerator = try inner.decode(String.self, forKey: .num)
            let denominator = try inner.decode(String.self, forKey: .den)
            self = .fraction(numerator: numerator, denominator: denominator)
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "prompt part has neither text nor frac")
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .text(let text):
            try container.encode(text, forKey: .text)
        case .fraction(let numerator, let denominator):
            var inner = container.nestedContainer(keyedBy: FractionKeys.self, forKey: .frac)
            try inner.encode(numerator, forKey: .num)
            try inner.encode(denominator, forKey: .den)
        }
    }
}

/// A curated practice problem. The iPad only ever sees the prompt; solutions live on the server.
struct Problem: Identifiable, Hashable, Codable {
    let id: String
    let promptPlain: String
    let promptLatex: String?
    let promptParts: [PromptPart]

    private enum CodingKeys: String, CodingKey {
        case id
        case promptPlain = "prompt_plain"
        case promptLatex = "prompt_latex"
        case promptParts = "prompt_parts"
    }

    init(id: String, promptPlain: String, promptLatex: String? = nil, promptParts: [PromptPart]? = nil) {
        self.id = id
        self.promptPlain = promptPlain
        self.promptLatex = promptLatex
        self.promptParts = promptParts ?? [.text(promptPlain)]
    }

    // MARK: - The student's own problem

    static let ownIDPrefix = "own:"

    /// A problem the student typed ("My own problem" in a course's list). Its id names the course and nothing else: the typed
    /// statement is the prompt, and it is also what the server is sent as `problem_text` (it has no bank entry to look up).
    static func own(courseSlug: String, text: String) -> Problem {
        Problem(id: ownIDPrefix + courseSlug, promptPlain: text)
    }

    var isOwn: Bool { id.hasPrefix(Self.ownIDPrefix) }

    /// The course slug inside an own problem's id; nil for a bank problem.
    var ownCourseSlug: String? { isOwn ? String(id.dropFirst(Self.ownIDPrefix.count)) : nil }

    /// What goes on the wire as `problem_text`: the typed statement for an own problem, nothing for a bank problem (the server
    /// already has those, and sending their text would let a stale copy disagree with the bank).
    var problemTextForServer: String? { isOwn ? promptPlain : nil }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let plain = try container.decode(String.self, forKey: .promptPlain)
        let latex = try container.decodeIfPresent(String.self, forKey: .promptLatex)
        let parts = try container.decodeIfPresent([PromptPart].self, forKey: .promptParts)
        self.init(id: id, promptPlain: plain, promptLatex: latex, promptParts: parts)
    }
}

/// The rules for the statement a student types in "My own problem". The server enforces the same ones (1 to 500 characters).
enum OwnProblemText {
    static let maxLength = 500

    /// The statement ready to send, or nil when nothing is typed. Line breaks become spaces (the statement is one line of text
    /// for the tutor) and the ends are trimmed. Longer than `maxLength` is cut, never rejected: the field already stops typing there.
    static func cleaned(_ typed: String) -> String? {
        let oneLine = typed.components(separatedBy: .newlines).joined(separator: " ")
        let trimmed = oneLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return capped(trimmed)
    }

    /// The first `maxLength` UTF-16 units, the way the server counts, without cutting a character in half.
    static func capped(_ text: String) -> String {
        guard text.utf16.count > maxLength else { return text }
        var kept = ""
        var units = 0
        for character in text {
            units += character.utf16.count
            if units > maxLength { break }
            kept.append(character)
        }
        return kept
    }
}

enum ProblemBank {
    static func decode(_ data: Data) throws -> [Problem] {
        try JSONDecoder().decode([Problem].self, from: data)
    }

    /// Loads `problems.json`, which the build copies into the app from `shared/problems.json`.
    static func loadBundled(bundle: Bundle = .main) throws -> [Problem] {
        guard let url = bundle.url(forResource: "problems", withExtension: "json") else {
            throw TutorError.problemBankMissing
        }
        let data = try Data(contentsOf: url)
        let problems = try decode(data)
        guard !problems.isEmpty else { throw TutorError.problemBankMissing }
        return problems
    }
}
