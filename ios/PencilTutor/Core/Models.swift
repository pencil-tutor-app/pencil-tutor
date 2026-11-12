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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let plain = try container.decode(String.self, forKey: .promptPlain)
        let latex = try container.decodeIfPresent(String.self, forKey: .promptLatex)
        let parts = try container.decodeIfPresent([PromptPart].self, forKey: .promptParts)
        self.init(id: id, promptPlain: plain, promptLatex: latex, promptParts: parts)
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
