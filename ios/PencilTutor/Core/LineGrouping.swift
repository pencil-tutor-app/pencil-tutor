import CoreGraphics
import Foundation

/// The bounds and time of one pen stroke, with the PencilKit types stripped away so grouping can be unit tested.
struct InkStroke: Equatable {
    let id: Int
    let bounds: CGRect
    let createdAt: Date
}

/// One line of the student's work, as the tutor sees it.
struct InkLine: Equatable {
    /// 1-based, top to bottom. This is the number drawn in the margin of the snapshot.
    let index: Int
    let box: CGRect
    let strokeIDs: [Int]
    let lastStrokeAt: Date
    /// True for a side calculation: work set apart to the right of the main working.
    let isSideCalculation: Bool

    /// True when the same ink is still there, unchanged. Ignores the index, because lines renumber when
    /// the student writes above them.
    func isSameInk(as other: InkLine) -> Bool {
        strokeIDs.count == other.strokeIDs.count
            && lastStrokeAt == other.lastStrokeAt
            && abs(box.minX - other.box.minX) <= 1
            && abs(box.minY - other.box.minY) <= 1
            && abs(box.maxX - other.box.maxX) <= 1
            && abs(box.maxY - other.box.maxY) <= 1
    }
}

/// Groups pen strokes into lines of work.
///
/// This is a HYPOTHESIS (plan amendment 7), not a proven rule, but it is now checked against a few thousand synthetic pages
/// (`tools/handwriting`, `docs/evals/2026-11-15-handwriting-replay.md`). Everything is measured in units of `letter`, the height of
/// a typical letter or digit on this page, so the rules do not depend on how big the student writes. The steps, in order:
///  1. A stacked fraction (a flat bar with writing above and below it) is one piece, so its rows cannot become separate lines.
///  2. Pieces whose heights overlap form a band. A band is a line, or several lines the student wrote so close that they touch.
///  3. A band that touches several lines is cut where the ink thins out between two thick rows (a valley), never through a
///     fraction. Rows of writing are thick (many letters side by side); the gap between two lines is thin.
///  4. A band with nothing but small marks in it (a raised exponent, a subscript that sits clear of its line) belongs to the
///     nearest line it stands beside, instead of becoming a line of its own.
///  5. A very tall stroke (a scribble crossing out work, a big bracket) joins the line its middle falls in and does not stretch it.
///  6. Work set far to the right of the same band (a side calculation) becomes its own line.
struct LineGrouper {
    /// Horizontal gap (points) that separates a side calculation from the main working.
    var sideGap: CGFloat = 160
    /// A valley between two lines may hold at most this share of the ink of the thinner of the two rows around it.
    var valleyShare: CGFloat = 0.4

    // MARK: - Pieces

    private enum Kind {
        /// A letter, digit or bracket of ordinary size.
        case body
        /// Smaller than a letter and not a dash: a raised exponent, a subscript, a comma.
        case small
        /// A dash: a minus, one half of an equals sign, a fraction bar on its own.
        case flat
        /// A whole stacked fraction.
        case fraction
        /// Taller than any letter: a crossing-out scribble, a big bracket.
        case tall
    }

    /// A stroke, or the strokes of one fraction, that always stay on the same line.
    private struct Piece {
        let kind: Kind
        let strokes: [InkStroke]
        let rect: CGRect
        let lastAt: Date

        init(kind: Kind, strokes: [InkStroke]) {
            self.kind = kind
            self.strokes = strokes
            self.rect = strokes.map { $0.bounds }.reduce(CGRect.null) { $0.union($1) }
            self.lastAt = strokes.map { $0.createdAt }.max() ?? Date.distantPast
        }
    }

    /// Pieces that sit at the same height.
    private struct Band {
        var pieces: [Piece]
        var rect: CGRect { pieces.map { $0.rect }.reduce(CGRect.null) { $0.union($1) } }
        /// Only small marks: a candidate for being attached to a line instead of standing alone.
        var isOnlySmallMarks: Bool { pieces.allSatisfy { $0.kind == .small || $0.kind == .flat } }
    }

    // MARK: - Grouping

    func group(_ strokes: [InkStroke]) -> [InkLine] {
        let usable = strokes.filter { !$0.bounds.isNull && !$0.bounds.isInfinite }
        guard !usable.isEmpty else { return [] }

        let letter = Self.letterHeight(of: usable)
        let pieces = makePieces(usable, letter: letter)
        let ordinary = pieces.filter { $0.kind != .tall }
        let tall = pieces.filter { $0.kind == .tall }

        var bands = makeBands(ordinary).flatMap { splitAtValleys($0, letter: letter) }
        bands = attachSmallMarks(bands, letter: letter)
        bands = attachTall(tall, to: bands)
        bands.sort { $0.rect.minY < $1.rect.minY }

        let globalMinX = usable.map { $0.bounds.minX }.min() ?? 0
        var result: [InkLine] = []
        for band in bands {
            let ordered = band.pieces.sorted { $0.rect.minX < $1.rect.minX }
            var segments: [[Piece]] = []
            var runningMaxX = -CGFloat.infinity
            for piece in ordered {
                if segments.isEmpty || piece.rect.minX - runningMaxX > sideGap {
                    segments.append([piece])
                } else {
                    segments[segments.count - 1].append(piece)
                }
                runningMaxX = max(runningMaxX, piece.rect.maxX)
            }
            for (segmentIndex, segment) in segments.enumerated() {
                let box = segment.map { $0.rect }.reduce(CGRect.null) { $0.union($1) }
                let ids = segment.flatMap { $0.strokes.map { $0.id } }.sorted()
                let last = segment.map { $0.lastAt }.max() ?? Date.distantPast
                let isSide = segmentIndex > 0 || (box.minX - globalMinX) > sideGap
                result.append(InkLine(index: 0, box: box, strokeIDs: ids, lastStrokeAt: last, isSideCalculation: isSide))
            }
        }

        result.sort { a, b in
            if a.box.minY != b.box.minY { return a.box.minY < b.box.minY }
            return a.box.minX < b.box.minX
        }
        return result.enumerated().map { offset, line in
            InkLine(index: offset + 1, box: line.box, strokeIDs: line.strokeIDs,
                    lastStrokeAt: line.lastStrokeAt, isSideCalculation: line.isSideCalculation)
        }
    }

    // MARK: - Sizes

    /// A dash is wide and flat: at least four times as wide as it is tall (or too thin to measure).
    private static func isFlat(_ rect: CGRect, letter: CGFloat = .infinity) -> Bool {
        rect.height <= max(4, min(rect.width / 4, 0.3 * letter))
    }

    /// The height of a typical letter or digit on this page: the median over strokes that are not dashes and not specks. Does not
    /// move when the page is full of dashes, exponents or brackets, which is what made the old median unreliable.
    static func letterHeight(of strokes: [InkStroke]) -> CGFloat {
        let sized = strokes.map { $0.bounds }.filter { !isFlat($0) && $0.height >= 6 }.map { $0.height }.sorted()
        if !sized.isEmpty { return sized[sized.count / 2] }
        let any = strokes.map { $0.bounds.height }.sorted()
        return max(any[any.count / 2], 1)
    }

    // MARK: - Step 1: pieces and stacked fractions

    private func makePieces(_ strokes: [InkStroke], letter: CGFloat) -> [Piece] {
        let fractions = fractionGroups(strokes, letter: letter)
        let inFraction = Set(fractions.flatMap { $0.map { $0.id } })

        var pieces = fractions.map { Piece(kind: .fraction, strokes: $0) }
        for stroke in strokes where !inFraction.contains(stroke.id) {
            let rect = stroke.bounds
            let kind: Kind
            if rect.height > 2.5 * letter {
                kind = .tall
            } else if Self.isFlat(rect, letter: letter) {
                kind = .flat
            } else if rect.height < 0.6 * letter {
                kind = .small
            } else {
                kind = .body
            }
            pieces.append(Piece(kind: kind, strokes: [stroke]))
        }
        return pieces
    }


    /// A stroke that sits right over or right under a bar, and how far the gap between them is.
    private struct Neighbour {
        let stroke: InkStroke
        let gap: CGFloat
    }

    /// A flat bar with a row of writing right above it and a row right below it, together with that writing. Reach is a bit over
    /// half a letter height: a numerator is written close to its bar, while the next line of writing is not.
    private func fractionGroups(_ strokes: [InkStroke], letter: CGFloat) -> [[InkStroke]] {
        let bars = strokes.filter { Self.isFlat($0.bounds, letter: letter) && $0.bounds.width >= max(10, 0.5 * letter) }
        guard !bars.isEmpty else { return [] }
        let candidates = strokes.filter { !Self.isFlat($0.bounds, letter: letter) && $0.bounds.height <= 1.8 * letter }

        // What each bar would take with it: the nearest row of writing above, the nearest row below. Only bars that find both.
        var proposals: [(bar: InkStroke, above: [Neighbour], below: [Neighbour])] = []
        for bar in bars {
            // A stroke crossing the bar's middle makes it a cross, not a bar: the horizontal of a + or ±, the crossbar of a t.
            guard !strokes.contains(where: { isCrossing(bar: bar.bounds, $0, letter: letter) }) else { continue }
            let (above, below) = neighbours(of: bar, among: candidates, letter: letter)
            guard !above.isEmpty, !below.isEmpty else { continue }
            // In a fraction the writing sits about as far above the bar as below it. A bar with a letter touching one side and a
            // different line a long way off the other is the top of a 7 or a 5, not a fraction.
            let nearest = [above, below].map { side in side.map { $0.gap }.min() ?? 0 }
            guard nearest.max()! <= 2 * nearest.min()! + 0.15 * letter else { continue }
            proposals.append((bar, above, below))
        }

        // A stroke wanted by two fractions goes with the nearer bar.
        var owner: [Int: (proposal: Int, gap: CGFloat)] = [:]
        for (index, proposal) in proposals.enumerated() {
            for neighbour in proposal.above + proposal.below {
                if owner[neighbour.stroke.id] == nil || neighbour.gap < owner[neighbour.stroke.id]!.gap {
                    owner[neighbour.stroke.id] = (index, neighbour.gap)
                }
            }
        }
        var groups: [[InkStroke]] = []
        for (index, proposal) in proposals.enumerated() {
            let above = proposal.above.filter { owner[$0.stroke.id]?.proposal == index }
            let below = proposal.below.filter { owner[$0.stroke.id]?.proposal == index }
            guard !above.isEmpty, !below.isEmpty else { continue }
            groups.append([proposal.bar] + (above + below).map { $0.stroke })
        }
        return groups
    }

    private func isCrossing(bar: CGRect, _ stroke: InkStroke, letter: CGFloat) -> Bool {
        let rect = stroke.bounds
        let tolerance = 0.15 * letter
        let middleStart = bar.minX + 0.2 * bar.width, middleEnd = bar.maxX - 0.2 * bar.width
        return !Self.isFlat(rect, letter: letter) && rect.midX >= middleStart && rect.midX <= middleEnd
            && rect.minY < bar.midY - tolerance && rect.maxY > bar.midY + tolerance
    }

    /// The rows of writing right above and right below a bar. Writing above a bar sits above its middle and writing below sits
    /// below it (give or take the width of the pen); a stroke that crosses the bar is part of the same letter (the crossbar of an
    /// f). Only the row against the bar counts: a stroke a whole row further out belongs to another line.
    private func neighbours(of bar: InkStroke, among candidates: [InkStroke], letter: CGFloat) -> (above: [Neighbour], below: [Neighbour]) {
        let barRect = bar.bounds
        let slack = barRect.width * 0.15
        let tolerance = 0.15 * letter
        var above: [Neighbour] = [], below: [Neighbour] = []
        for candidate in candidates {
            let rect = candidate.bounds
            guard rect.midX >= barRect.minX - slack, rect.midX <= barRect.maxX + slack else { continue }
            if rect.maxY <= barRect.midY + tolerance {
                above.append(Neighbour(stroke: candidate, gap: max(0, barRect.minY - rect.maxY)))
            } else if rect.minY >= barRect.midY - tolerance {
                below.append(Neighbour(stroke: candidate, gap: max(0, rect.minY - barRect.maxY)))
            }
        }
        func nearestRow(_ side: [Neighbour]) -> [Neighbour] {
            let nearest = side.map { $0.gap }.min() ?? 0
            return side.filter { $0.gap <= min(nearest + 0.6 * letter, 0.55 * letter) }
        }
        return (nearestRow(above), nearestRow(below))
    }


    // MARK: - Step 2: bands

    /// Pieces whose heights overlap (or all but touch) end up in the same band, however long the chain.
    private func makeBands(_ pieces: [Piece]) -> [Band] {
        let sorted = pieces.sorted { $0.rect.minY < $1.rect.minY }
        var bands: [Band] = []
        var currentMaxY = -CGFloat.infinity
        for piece in sorted {
            if bands.isEmpty || piece.rect.minY > currentMaxY + 1 {
                bands.append(Band(pieces: [piece]))
                currentMaxY = piece.rect.maxY
            } else {
                bands[bands.count - 1].pieces.append(piece)
                currentMaxY = max(currentMaxY, piece.rect.maxY)
            }
        }
        return bands
    }

    // MARK: - Step 3: cut a band where the ink thins out

    private func splitAtValleys(_ band: Band, letter: CGFloat) -> [Band] {
        let rect = band.rect
        guard band.pieces.count > 1, rect.height >= 1.8 * letter else { return [band] }

        // Ink per height: how much horizontal ink crosses each point-high slice of the band. A row of writing is thick, the gap
        // between two rows is thin. Strokes count one by one, so a stacked fraction's empty middle is not thick.
        let base = floor(rect.minY)
        let slices = Int(ceil(rect.maxY - base)) + 1
        var change = [CGFloat](repeating: 0, count: slices + 1)
        for piece in band.pieces {
            for stroke in piece.strokes {
                let first = max(0, Int(floor(stroke.bounds.minY - base)))
                let last = min(slices - 1, Int(floor(stroke.bounds.maxY - base)))
                guard first <= last else { continue }
                let weight = max(stroke.bounds.width, 2)
                change[first] += weight
                change[last + 1] -= weight
            }
        }
        var ink = [CGFloat](repeating: 0, count: slices)
        var running: CGFloat = 0
        for slice in 0..<slices {
            running += change[slice]
            ink[slice] = running
        }

        // Where a cut is allowed: not near the top or bottom of the band (that would shave off an exponent or a tail), and never
        // through a stacked fraction.
        let margin = Int(ceil(0.5 * letter))
        guard slices > 2 * margin + 1 else { return [band] }
        let fractionSpans = band.pieces.filter { $0.kind == .fraction }.map { $0.rect }
        var cut: Int?
        for slice in margin..<(slices - margin) {
            let y = base + CGFloat(slice)
            if fractionSpans.contains(where: { y > $0.minY && y < $0.maxY }) { continue }
            if cut == nil || ink[slice] < ink[cut!] { cut = slice }
        }
        guard let cut else { return [band] }
        // Wander to the middle of a flat stretch of valley, so the cut does not hug one side.
        var lowEnd = cut, highEnd = cut
        while lowEnd > margin, ink[lowEnd - 1] <= ink[cut] { lowEnd -= 1 }
        while highEnd < slices - margin - 1, ink[highEnd + 1] <= ink[cut] { highEnd += 1 }
        let middle = (lowEnd + highEnd) / 2

        let above = ink[0...cut].max() ?? 0
        let below = ink[cut...].max() ?? 0
        guard ink[cut] <= valleyShare * min(above, below) else { return [band] }

        let cutY = base + CGFloat(middle)
        let top = band.pieces.filter { $0.rect.midY < cutY }
        let bottom = band.pieces.filter { $0.rect.midY >= cutY }
        guard !top.isEmpty, !bottom.isEmpty else { return [band] }
        return splitAtValleys(Band(pieces: top), letter: letter) + splitAtValleys(Band(pieces: bottom), letter: letter)
    }

    // MARK: - Step 4: small marks stay with the line they stand beside

    private func attachSmallMarks(_ bands: [Band], letter: CGFloat) -> [Band] {
        var lines = bands.filter { !$0.isOnlySmallMarks }
        let marks = bands.filter { $0.isOnlySmallMarks }
        guard !lines.isEmpty else { return bands }

        var loose: [Band] = []
        for mark in marks {
            var best: (index: Int, distance: CGFloat)?
            for (index, line) in lines.enumerated() {
                let up = max(0, mark.rect.minY - line.rect.maxY)
                let down = max(0, line.rect.minY - mark.rect.maxY)
                let vertical = max(up, down)
                guard vertical <= 0.8 * letter else { continue }
                let horizontal = line.pieces.map { Self.horizontalGap($0.rect, mark.rect) }.min() ?? .infinity
                guard horizontal <= 1.2 * letter else { continue }
                let distance = vertical + horizontal
                if best == nil || distance < best!.distance { best = (index, distance) }
            }
            if let best {
                lines[best.index].pieces.append(contentsOf: mark.pieces)
            } else {
                loose.append(mark)
            }
        }
        return lines + loose
    }

    private static func horizontalGap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, max(a.minX - b.maxX, b.minX - a.maxX))
    }

    // MARK: - Step 5: tall strokes

    /// A tall stroke joins the band its middle falls in (the one it overlaps most if several), without stretching the band's
    /// range, so a scribble over line 1 cannot pull line 2 in. With no such band it stands alone.
    private func attachTall(_ tall: [Piece], to bands: [Band]) -> [Band] {
        var bands = bands
        let ranges = bands.map { $0.rect }      // fixed first, so one scribble cannot stretch a band for the next
        for piece in tall.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            var bestIndex: Int?
            var bestOverlap: CGFloat = -1
            for index in ranges.indices {
                let range = ranges[index]
                guard piece.rect.midY >= range.minY, piece.rect.midY <= range.maxY else { continue }
                let overlap = max(0, min(piece.rect.maxY, range.maxY) - max(piece.rect.minY, range.minY))
                if overlap > bestOverlap {
                    bestIndex = index
                    bestOverlap = overlap
                }
            }
            if let bestIndex {
                bands[bestIndex].pieces.append(piece)
            } else {
                bands.append(Band(pieces: [piece]))
            }
        }
        return bands
    }
}
