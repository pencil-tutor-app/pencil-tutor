import CoreGraphics
import Foundation

/// What one pen stroke is, in a form that survives what the page does to ink when the student has not written anything.
///
/// `InkStroke.id` is only the stroke's position in `PKDrawing.strokes`: erasing an earlier stroke renumbers every later one, so an
/// id cannot say "the same stroke as before". Position on the page cannot either: a page re-anchor (`TutorSession.reanchorPage`)
/// moves the whole drawing. What stays put is when the stroke was started (`PKStrokePath.creationDate`, one per pen-down) and how
/// big it is. Moving ink around (re-anchor, a lasso drag) changes neither; rewriting a stroke gives it a new start time.
struct StrokeFingerprint: Equatable {
    /// Seconds since the reference date, so it compares and sorts as a number.
    let startedAt: TimeInterval
    let width: CGFloat
    let height: CGFloat

    init(_ stroke: InkStroke) {
        startedAt = stroke.createdAt.timeIntervalSinceReferenceDate
        width = stroke.bounds.width
        height = stroke.bounds.height
    }

    /// Start times agree to the millisecond and sizes to a point (the sizes are floats that were moved and rounded by the page).
    func matches(_ other: StrokeFingerprint) -> Bool {
        abs(startedAt - other.startedAt) < 0.001 && abs(width - other.width) <= 1 && abs(height - other.height) <= 1
    }

    fileprivate static func inOrder(_ a: StrokeFingerprint, _ b: StrokeFingerprint) -> Bool {
        if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
        if a.width != b.width { return a.width < b.width }
        return a.height < b.height
    }
}

/// The ink of one line of work, as a list of stroke fingerprints, oldest first. Two identities are the same ink when they hold the
/// same strokes: one stroke added, erased or redrawn makes them different, however the lines are numbered and wherever the page is.
struct InkIdentity: Equatable {
    static let none = InkIdentity(fingerprints: [])

    let strokes: [StrokeFingerprint]

    private init(fingerprints: [StrokeFingerprint]) {
        strokes = fingerprints.sorted(by: StrokeFingerprint.inOrder)
    }

    init(strokes: [InkStroke]) {
        self.init(fingerprints: strokes.map(StrokeFingerprint.init))
    }

    /// The strokes of `line`, looked up in the `strokes` the line was grouped from (the line holds positions, not strokes).
    init(line: InkLine, in strokes: [InkStroke]) {
        let wanted = Set(line.strokeIDs)
        self.init(strokes: strokes.filter { wanted.contains($0.id) })
    }

    var isEmpty: Bool { strokes.isEmpty }

    func isSameInk(as other: InkIdentity) -> Bool {
        strokes.count == other.strokes.count && zip(strokes, other.strokes).allSatisfy { $0.matches($1) }
    }

    /// Every stroke of this ink is still on the page (it may have more ink around it now). False once one was erased or redrawn.
    func isStillOnPage(_ page: [InkStroke]) -> Bool {
        var unused = page.map(StrokeFingerprint.init)
        for wanted in strokes {
            guard let index = unused.firstIndex(where: { wanted.matches($0) }) else { return false }
            unused.remove(at: index)
        }
        return true
    }
}

/// One "Not a mistake" tap: the ink the tutor was wrong about. Lives as long as that ink is untouched.
struct Dispute: Equatable {
    /// The line number the student saw when they tapped. Numbers change as lines are added above; the ink is what counts.
    let lineIndex: Int
    let requestID: String?
    let ink: InkIdentity
}

/// Every dispute of one problem screen. The tutor may not circle disputed ink again, however many looks pass and however the
/// lines are renumbered. A real edit to that ink (a stroke erased or redrawn) ends the dispute; adding a stroke to the line
/// gives the line a different identity, so a look at the new line is not covered (and the dispute comes back if it is erased).
struct DisputeBook {
    static let limit = 40

    private(set) var disputes: [Dispute] = []

    var count: Int { disputes.count }

    mutating func add(_ dispute: Dispute) {
        disputes.removeAll { $0.ink.isSameInk(as: dispute.ink) }
        disputes.append(dispute)
        if disputes.count > Self.limit { disputes.removeFirst(disputes.count - Self.limit) }
    }

    /// The dispute that covers exactly this ink, if any. Empty ink is never covered.
    func covering(_ ink: InkIdentity) -> Dispute? {
        guard !ink.isEmpty else { return nil }
        return disputes.first { $0.ink.isSameInk(as: ink) }
    }

    /// Drops the disputes whose ink is no longer all on the page, and returns them.
    @discardableResult
    mutating func dropEdited(page: [InkStroke]) -> [Dispute] {
        let ended = disputes.filter { !$0.ink.isStillOnPage(page) }
        guard !ended.isEmpty else { return [] }
        disputes.removeAll { dispute in ended.contains(dispute) }
        return ended
    }

    @discardableResult
    mutating func removeAll() -> Int {
        let had = disputes.count
        disputes = []
        return had
    }
}
