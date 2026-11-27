import CoreGraphics
import Foundation

/// Has the student really started the practice problem? The answer decides whether the tutor may say anything near the final
/// answer (`attempted` on ask, consult and follow-up, and a line pushed into the live voice).
///
/// Geometry only: no handwriting recognition. The rule is deliberately conservative, because a wrong "not yet" only keeps the
/// guard on a little longer, while a wrong "yes" gives the answer away. A line of the page counts as work when:
///  - it is part of the main working, not a side calculation (a lone scribble far to the right is not the answer);
///  - it holds at least `minimumStrokes` strokes and is at least `minimumWidthInLetters` letter heights wide (a dot, a dash, an
///    "x" or a doodle is not a line of work);
///  - it is not crossed out: some stroke, as wide as at least `strikeShare` of the rest of the line, runs through at least two of
///    the other strokes (a strike-through, a slash or a scribble; an underline or a fraction bar runs beside the strokes, not through them).
/// And the same work line must have stayed exactly as it was across one look: the page is seen twice (at a look, then at the next
/// look or at a question), and counts as attempted only when a work line it holds now is unchanged from the line the last look
/// stored. So a line the student is still writing, a line edited or erased since the last look, a line seen for the first time
/// and a page just cleared are all "not yet".
enum AttemptRule {
    static let minimumStrokes = 4
    static let minimumWidthInLetters: CGFloat = 2.5
    static let strikeShare: CGFloat = 0.6

    /// The lines of real work on the page, top to bottom.
    static func workLines(_ strokes: [InkStroke], grouper: LineGrouper = LineGrouper()) -> [InkLine] {
        let lines = grouper.group(strokes)
        guard !lines.isEmpty else { return [] }
        let letter = LineGrouper.letterHeight(of: strokes)
        let byID = Dictionary(strokes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return lines.filter { line in
            guard !line.isSideCalculation, line.strokeIDs.count >= minimumStrokes, line.box.width >= minimumWidthInLetters * letter else {
                return false
            }
            let own = line.strokeIDs.compactMap { byID[$0] }
            return !isCrossedOut(own, by: strokes)
        }
    }

    /// True when some stroke on the page (the line's own, or a big scribble that joined another line) runs through the line.
    static func isCrossedOut(_ own: [InkStroke], by page: [InkStroke]) -> Bool {
        for striker in page {
            let others = own.filter { $0.id != striker.id }
            guard others.count >= 2 else { continue }
            let box = others.map { $0.bounds }.reduce(CGRect.null) { $0.union($1) }
            guard striker.bounds.width >= strikeShare * box.width else { continue }
            let through = others.filter { runsThrough(striker.bounds, $0.bounds) }.count
            if through >= 2 && Double(through) >= 0.4 * Double(others.count) { return true }
        }
        return false
    }

    /// The striker covers the other stroke sideways and its height range includes the stroke's middle (give or take a quarter of
    /// the stroke's height), so a bar above or below the stroke does not count.
    private static func runsThrough(_ striker: CGRect, _ other: CGRect) -> Bool {
        let overlap = min(striker.maxX, other.maxX) - max(striker.minX, other.minX)
        guard overlap > 0 else { return false }
        let slack = 0.25 * other.height
        return striker.minY - slack <= other.midY && other.midY <= striker.maxY + slack
    }
}

/// Remembers the work lines of the latest look. `attempted` is true while a work line on the page now is the same ink as one of them.
struct AttemptTracker {
    private var lookedAt: [InkLine] = []

    /// A look is starting on this page. Returns whether the page is attempted (judged against the previous look), then stores this
    /// look's work lines for the next judgement.
    @discardableResult
    mutating func look(_ strokes: [InkStroke]) -> Bool {
        let result = attempted(strokes)
        lookedAt = AttemptRule.workLines(strokes)
        return result
    }

    /// The page was erased or replaced: nothing seen counts any more.
    mutating func reset() {
        lookedAt = []
    }

    func attempted(_ strokes: [InkStroke]) -> Bool {
        guard !lookedAt.isEmpty else { return false }
        return AttemptRule.workLines(strokes).contains { line in lookedAt.contains { $0.isSameInk(as: line) } }
    }

    /// For the log: how many work lines the latest look held.
    var workLinesAtLastLook: Int { lookedAt.count }
}
