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
/// This is a HYPOTHESIS (plan amendment 7), not a proven rule. The pieces:
///  1. Vertical overlap puts strokes on the same line.
///  2. A stacked fraction (a wide flat bar with strokes above and below it) becomes one unit, so its three
///     rows are one line instead of three.
///  3. A crossed-out scribble that is much taller than normal writing joins the line its middle falls in, and
///     does not stretch that line, so it cannot swallow the line below.
///  4. Work set far to the right of the same band (a side calculation) becomes its own line.
struct LineGrouper {
    /// Horizontal gap (points) that separates a side calculation from the main working.
    var sideGap: CGFloat = 160
    /// How much of the shorter item must overlap vertically for two items to share a line.
    var minOverlapRatio: CGFloat = 0.5

    private struct Unit {
        var strokeIDs: [Int]
        var rect: CGRect
        var lastAt: Date
        var isTallSingle: Bool
    }

    private struct LineBuild {
        var range: CGRect      // vertical extent that decides membership (excludes tall scribbles)
        var units: [Unit]
    }

    func group(_ strokes: [InkStroke]) -> [InkLine] {
        let usable = strokes.filter { !$0.bounds.isNull && !$0.bounds.isInfinite }
        guard !usable.isEmpty else { return [] }

        let heights = usable.map { $0.bounds.height }.sorted()
        let medianHeight = max(heights[heights.count / 2], 1)

        let units = makeUnits(usable, medianHeight: medianHeight)
        var lines = assignToLines(units)
        lines = lines.sorted { $0.range.minY < $1.range.minY }

        let globalMinX = usable.map { $0.bounds.minX }.min() ?? 0
        var result: [InkLine] = []
        for line in lines {
            let ordered = line.units.sorted { $0.rect.minX < $1.rect.minX }
            var segments: [[Unit]] = []
            var runningMaxX = -CGFloat.infinity
            for unit in ordered {
                if segments.isEmpty || unit.rect.minX - runningMaxX > sideGap {
                    segments.append([unit])
                } else {
                    segments[segments.count - 1].append(unit)
                }
                runningMaxX = max(runningMaxX, unit.rect.maxX)
            }
            for (segmentIndex, segment) in segments.enumerated() {
                let box = segment.map { $0.rect }.reduce(CGRect.null) { $0.union($1) }
                let ids = segment.flatMap { $0.strokeIDs }.sorted()
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

    // MARK: - Step 1: fractions and units

    private func isBarLike(_ rect: CGRect) -> Bool {
        rect.width >= 28 && rect.width >= 4 * max(rect.height, 2)
    }

    private func makeUnits(_ strokes: [InkStroke], medianHeight: CGFloat) -> [Unit] {
        let bars = strokes.filter { isBarLike($0.bounds) }

        // Each non-bar stroke may belong to the nearest bar it sits directly above or below.
        var barForStroke: [Int: Int] = [:]
        for candidate in strokes where !isBarLike(candidate.bounds) {
            var best: (barID: Int, gap: CGFloat)?
            for bar in bars {
                let barRect = bar.bounds
                let slack = barRect.width * 0.15
                let midX = candidate.bounds.midX
                guard midX >= barRect.minX - slack, midX <= barRect.maxX + slack else { continue }
                let gap: CGFloat
                if candidate.bounds.midY < barRect.midY {
                    gap = barRect.minY - candidate.bounds.maxY
                } else if candidate.bounds.midY > barRect.midY {
                    gap = candidate.bounds.minY - barRect.maxY
                } else {
                    continue
                }
                let reach = max(30, min(1.5 * barRect.width, 2.5 * medianHeight))
                let distance = max(0, gap)
                guard distance <= reach else { continue }
                if best == nil || distance < best!.gap { best = (bar.id, distance) }
            }
            if let best { barForStroke[candidate.id] = best.barID }
        }

        var consumed = Set<Int>()
        var units: [Unit] = []
        for bar in bars {
            let memberIDs = barForStroke.filter { $0.value == bar.id }.map { $0.key }
            let members = strokes.filter { memberIDs.contains($0.id) }
            let hasAbove = members.contains { $0.bounds.midY < bar.bounds.midY }
            let hasBelow = members.contains { $0.bounds.midY > bar.bounds.midY }
            guard hasAbove && hasBelow else { continue }
            let all = [bar] + members
            units.append(Unit(
                strokeIDs: all.map { $0.id },
                rect: all.map { $0.bounds }.reduce(CGRect.null) { $0.union($1) },
                lastAt: all.map { $0.createdAt }.max() ?? Date.distantPast,
                isTallSingle: false
            ))
            for stroke in all { consumed.insert(stroke.id) }
        }

        for stroke in strokes where !consumed.contains(stroke.id) {
            let tall = !isBarLike(stroke.bounds) && stroke.bounds.height > 2.5 * medianHeight
            units.append(Unit(strokeIDs: [stroke.id], rect: stroke.bounds, lastAt: stroke.createdAt, isTallSingle: tall))
        }
        return units
    }

    // MARK: - Step 2: vertical overlap

    private func verticalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
    }

    private func assignToLines(_ units: [Unit]) -> [LineBuild] {
        let normal = units.filter { !$0.isTallSingle }.sorted { $0.rect.midY < $1.rect.midY }
        let tall = units.filter { $0.isTallSingle }.sorted { $0.rect.midY < $1.rect.midY }

        var lines: [LineBuild] = []

        for unit in normal {
            var bestIndex: Int?
            var bestOverlap: CGFloat = -1
            for (index, line) in lines.enumerated() {
                let overlap = verticalOverlap(unit.rect, line.range)
                let shorter = max(min(unit.rect.height, line.range.height), 1)
                let sharesLine = overlap / shorter >= minOverlapRatio
                    || (unit.rect.midY >= line.range.minY && unit.rect.midY <= line.range.maxY)
                if sharesLine && overlap > bestOverlap {
                    bestIndex = index
                    bestOverlap = overlap
                }
            }
            if let bestIndex {
                lines[bestIndex].units.append(unit)
                lines[bestIndex].range = lines[bestIndex].range.union(unit.rect)
            } else {
                lines.append(LineBuild(range: unit.rect, units: [unit]))
            }
        }

        for unit in tall {
            var bestIndex: Int?
            var bestOverlap: CGFloat = -1
            for (index, line) in lines.enumerated() {
                guard unit.rect.midY >= line.range.minY, unit.rect.midY <= line.range.maxY else { continue }
                let overlap = verticalOverlap(unit.rect, line.range)
                if overlap > bestOverlap {
                    bestIndex = index
                    bestOverlap = overlap
                }
            }
            if let bestIndex {
                lines[bestIndex].units.append(unit)   // joins the line but does not stretch its range
            } else {
                lines.append(LineBuild(range: unit.rect, units: [unit]))
            }
        }
        return lines
    }
}
