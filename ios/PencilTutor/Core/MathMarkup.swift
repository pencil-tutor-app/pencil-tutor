import Foundation

/// A piece of a problem statement, ready to be set in type. Pure data: the SwiftUI drawing lives in `MathViews.swift`.
indirect enum MathNode: Equatable {
    case text(String)
    /// A raised exponent: `x^2`, `e^(−3x)`, `x²`.
    case sup([MathNode])
    /// A lowered index: `a_{n+1}`, `v₁`.
    case sub([MathNode])
    /// A big operator with its bounds stacked above and below, as in Σ from k=1 to 20.
    case limits(symbol: String, lower: [MathNode], upper: [MathNode])
    /// A root: index nil is a square root, 3 a cube root. The content sits under the overbar.
    case root(index: Int?, [MathNode])
    /// A matrix, rows of cells.
    case matrix([[[MathNode]]])
}

/// Reads the way problems are written in `prompt_plain` (and in the text of `prompt_parts`) and turns it into `MathNode`s.
///
/// The notation is the small subset that every problem bank uses, so no LaTeX engine is needed and nothing is fetched:
///  - `^` and `_` with a group in `( )` or `{ }`, or one token (a number, or a single letter, with an optional sign): `x^(1/3)`,
///    `2^k`, `a_{n+1}`, `B_B`. Unicode superscripts and subscripts (`x²`, `v₁`, `A⁻¹`, `Mᵀ`) are read the same way, so every
///    exponent on the card is drawn by one rule.
///  - `√x`, `√(2x + 1)`, `∛125`, `∛(8/27)`: a root with an overbar.
///  - `[1 2; 3 4]`: a matrix (a bracket group with a `;` in it). Other brackets, like the interval `[0, 2]`, stay text.
///  - `Σ_{k=1}^{20}`: the bounds go above and below the sigma.
/// Anything it does not recognise is left as the text it was, so a prompt is never cut or changed.
/// Why not `prompt_latex`: it mixes `\text{...}` wrappers with raw Unicode and bare `√3/2` in the same string (so it would need a
/// second parser for the exceptions), and the plain form is what the tutor and the logs already use.
enum MathMarkup {
    static func parse(_ source: String) -> [MathNode] {
        var parser = Parser(Array(source))
        return parser.parseAll()
    }

    /// The nodes as plain characters, markup removed: exponents and indices follow their base with `^` / `_` where more than one
    /// character is needed. For one-line places (the collapsed pill, the problem list) and for tests.
    static func plainText(_ nodes: [MathNode]) -> String {
        nodes.map { node -> String in
            switch node {
            case .text(let text): return text
            case .sup(let inner): return wrapped("^", inner)
            case .sub(let inner): return wrapped("_", inner)
            case .limits(let symbol, let lower, let upper): return symbol + wrapped("_", lower) + wrapped("^", upper)
            case .root(let index, let inner):
                return (index == 3 ? "∛" : "√") + "(" + plainText(inner) + ")"
            case .matrix(let rows):
                return "[" + rows.map { $0.map { plainText($0) }.joined(separator: " ") }.joined(separator: "; ") + "]"
            }
        }.joined()
    }

    private static func wrapped(_ mark: String, _ inner: [MathNode]) -> String {
        let text = plainText(inner)
        return text.count == 1 ? mark + text : mark + "(" + text + ")"
    }

    // MARK: - Words

    /// Cuts the nodes into words at spaces, so a layout can wrap between words and never inside one. Exponents, roots and matrices
    /// stay with the word they belong to (`x^(1/3)` is one word; so is `2√3`). A bracketed run that is not a matrix, like
    /// `[0, 2]`, is kept whole by turning its spaces into no-break spaces, unless it is so long it must be allowed to wrap.
    static func words(_ nodes: [MathNode]) -> [[MathNode]] {
        var words: [[MathNode]] = []
        var current: [MathNode] = []
        func endWord() {
            if !current.isEmpty { words.append(current) }
            current = []
        }
        for node in nodes {
            guard case .text(let raw) = node else {
                current.append(node)
                continue
            }
            let text = glueBrackets(raw)
            var piece = ""
            for character in text {
                if character == " " || character == "\n" {
                    if !piece.isEmpty { current.append(.text(piece)); piece = "" }
                    endWord()
                } else {
                    piece.append(character)
                }
            }
            if !piece.isEmpty { current.append(.text(piece)) }
        }
        endWord()
        return words
    }

    private static func glueBrackets(_ text: String) -> String {
        guard text.contains("["), let bracketed = try? NSRegularExpression(pattern: "\\[[^\\]]{1,34}\\]") else { return text }
        var glued = text
        for match in bracketed.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: glued) else { continue }
            glued.replaceSubrange(range, with: glued[range].replacingOccurrences(of: " ", with: "\u{00A0}"))
        }
        return glued
    }

    // MARK: - Size and height of scripts

    /// How a script at nesting `level` (1 = an exponent, 2 = an exponent of an exponent) is drawn, as shares of the base size:
    /// its own size, and how far its baseline moves up (positive) or down. Exponents rise by 40% of the base, indices drop 18%.
    static func scriptStyle(level: Int, raised: Bool) -> (scale: CGFloat, shift: CGFloat) {
        let scale = pow(0.7, CGFloat(max(level, 0)))
        return (scale, raised ? 0.4 : -0.18)
    }

    // MARK: - The parser

    private static let superscriptCharacters: [Character: String] = [
        "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9",
        "⁺": "+", "⁻": "−", "ⁿ": "n", "ˣ": "x", "ᵀ": "T", "ᶜ": "c", "ᵏ": "k", "ʸ": "y", "ᵗ": "t"
    ]
    private static let subscriptCharacters: [Character: String] = [
        "₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4", "₅": "5", "₆": "6", "₇": "7", "₈": "8", "₉": "9",
        "₊": "+", "₋": "−", "ₙ": "n", "ₖ": "k", "ᵢ": "i", "ⱼ": "j", "ₓ": "x"
    ]
    private static let bigOperators: Set<Character> = ["Σ", "∑", "∏"]
    private static let rootSigns: [Character: Int?] = ["√": nil, "∛": 3]

    private struct Parser {
        let chars: [Character]
        var position = 0

        init(_ chars: [Character]) { self.chars = chars }

        mutating func parseAll() -> [MathNode] {
            var nodes: [MathNode] = []
            var buffer = ""
            func flush() {
                if !buffer.isEmpty { nodes.append(.text(buffer)); buffer = "" }
            }
            while position < chars.count {
                let c = chars[position]
                if let run = scriptRun(startingAt: position, in: MathMarkup.superscriptCharacters) {
                    flush()
                    nodes.append(.sup([.text(run.text)]))
                    position = run.end
                } else if let run = scriptRun(startingAt: position, in: MathMarkup.subscriptCharacters) {
                    flush()
                    nodes.append(.sub([.text(run.text)]))
                    position = run.end
                } else if c == "^" || c == "_", let script = explicitScript(at: position) {
                    // A big operator keeps its bounds above and below: Σ_{k=1}^{20}.
                    if let last = buffer.last, MathMarkup.bigOperators.contains(last) {
                        buffer.removeLast()
                        flush()
                        position = script.end
                        var lower: [MathNode] = [], upper: [MathNode] = []
                        if script.raised { upper = script.inner } else { lower = script.inner }
                        if position < chars.count, chars[position] == (script.raised ? "_" : "^"),
                           let other = explicitScript(at: position) {
                            if other.raised { upper = other.inner } else { lower = other.inner }
                            position = other.end
                        }
                        nodes.append(.limits(symbol: String(last), lower: lower, upper: upper))
                    } else {
                        flush()
                        nodes.append(script.raised ? .sup(script.inner) : .sub(script.inner))
                        position = script.end
                    }
                } else if let indexOrNil = MathMarkup.rootSigns[c], let root = rootBody(after: position) {
                    flush()
                    nodes.append(.root(index: indexOrNil, root.inner))
                    position = root.end
                } else if c == "[", let matrix = matrixBody(at: position) {
                    flush()
                    nodes.append(.matrix(matrix.rows))
                    position = matrix.end
                } else {
                    buffer.append(c)
                    position += 1
                }
            }
            flush()
            return nodes
        }

        /// A run of Unicode superscript (or subscript) characters starting here, as the ordinary characters they stand for.
        private func scriptRun(startingAt start: Int, in table: [Character: String]) -> (text: String, end: Int)? {
            var end = start
            var text = ""
            while end < chars.count, let mapped = table[chars[end]] {
                text += mapped
                end += 1
            }
            return end > start ? (text, end) : nil
        }

        /// `^(...)`, `^{...}`, `^x`, `^−2`, and the same with `_`. Nil when what follows is not one of those, so the mark stays text.
        private func explicitScript(at index: Int) -> (inner: [MathNode], end: Int, raised: Bool)? {
            let raised = chars[index] == "^"
            let next = index + 1
            guard next < chars.count else { return nil }
            if chars[next] == "(" || chars[next] == "{" {
                let close: Character = chars[next] == "(" ? ")" : "}"
                guard let end = matching(open: chars[next], close: close, from: next) else { return nil }
                let inner = MathMarkup.parse(String(chars[(next + 1)..<end]))
                return (inner, end + 1, raised)
            }
            var end = next
            if end < chars.count, chars[end] == "−" || chars[end] == "-" { end += 1 }
            guard end < chars.count else { return nil }
            if chars[end].isNumber && chars[end].isASCII {
                while end < chars.count, chars[end].isASCII, chars[end].isNumber || (chars[end] == "." && end + 1 < chars.count && chars[end + 1].isNumber) {
                    end += 1
                }
            } else if chars[end].isLetter {
                end += 1
            } else {
                return nil
            }
            return (MathMarkup.parse(String(chars[next..<end])), end, raised)
        }

        /// What a root sign covers: a group in `( )`, or one number or letter.
        private func rootBody(after index: Int) -> (inner: [MathNode], end: Int)? {
            let next = index + 1
            guard next < chars.count else { return nil }
            if chars[next] == "(" {
                guard let end = matching(open: "(", close: ")", from: next) else { return nil }
                return (MathMarkup.parse(String(chars[(next + 1)..<end])), end + 1)
            }
            var end = next
            if chars[end].isNumber && chars[end].isASCII {
                while end < chars.count, chars[end].isASCII, chars[end].isNumber || (chars[end] == "." && end + 1 < chars.count && chars[end + 1].isNumber) {
                    end += 1
                }
            } else if chars[end].isLetter {
                end += 1
            } else {
                return nil
            }
            return (MathMarkup.parse(String(chars[next..<end])), end)
        }

        /// `[1 2; 3 4]`: a bracket with a `;` inside and no other bracket. Cells split at spaces.
        private func matrixBody(at index: Int) -> (rows: [[[MathNode]]], end: Int)? {
            var end = index + 1
            while end < chars.count, chars[end] != "]" {
                if chars[end] == "[" { return nil }
                end += 1
            }
            guard end < chars.count else { return nil }
            let inner = String(chars[(index + 1)..<end])
            guard inner.contains(";") else { return nil }
            let rows = inner.split(separator: ";").map { row in
                row.split(whereSeparator: { $0 == " " }).map { MathMarkup.parse(String($0)) }
            }.filter { !$0.isEmpty }
            guard !rows.isEmpty else { return nil }
            return (rows, end + 1)
        }

        /// The index of the bracket that closes the one at `start`, counting nested pairs.
        private func matching(open: Character, close: Character, from start: Int) -> Int? {
            var depth = 0
            var index = start
            while index < chars.count {
                if chars[index] == open { depth += 1 }
                if chars[index] == close {
                    depth -= 1
                    if depth == 0 { return index }
                }
                index += 1
            }
            return nil
        }
    }
}
