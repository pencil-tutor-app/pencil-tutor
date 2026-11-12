import Foundation

/// Decides when the tutor may look at the page. Pure logic with an injected clock value, so it is unit tested.
///
/// Rules (plan, "When to look"):
///  - never while a request is in flight (one at a time)
///  - only when the drawing changed since the last look
///  - only after the pen has been idle for `idleSeconds`
///  - never within `cooldownSeconds` after an interruption
struct LookPolicy: Equatable {
    var idleSeconds: TimeInterval
    var cooldownSeconds: TimeInterval

    enum Verdict: Equatable {
        case lookNow
        case waitUntil(Date, reason: String)
        case skip(reason: String)
    }

    func evaluate(
        now: Date,
        lastInkAt: Date?,
        drawingRevision: Int,
        lastLookRevision: Int,
        lastInterruptionAt: Date?,
        requestInFlight: Bool,
        penDown: Bool
    ) -> Verdict {
        if requestInFlight { return .skip(reason: "request already in flight") }
        if drawingRevision == lastLookRevision { return .skip(reason: "drawing unchanged since last look") }
        guard let lastInkAt else { return .skip(reason: "no ink yet") }
        if penDown { return .skip(reason: "pen is down") }

        let idleReadyAt = lastInkAt.addingTimeInterval(idleSeconds)
        let cooldownReadyAt = lastInterruptionAt?.addingTimeInterval(cooldownSeconds) ?? .distantPast
        let readyAt = max(idleReadyAt, cooldownReadyAt)

        if now >= readyAt { return .lookNow }
        let why = cooldownReadyAt > idleReadyAt ? "cooldown after interruption" : "waiting for pen to be idle"
        return .waitUntil(readyAt, reason: why)
    }
}

/// Decides what to do with a response that arrives after the student kept writing (plan amendment 5).
enum StaleResponseGate {
    enum Outcome: Equatable {
        case accept
        case discard(reason: String)
    }

    /// - Parameters:
    ///   - responseRevision: the drawing_revision the server echoed back.
    ///   - currentRevision: the drawing revision right now.
    ///   - lineStillUnchanged: whether the line the server named has exactly the same ink now as when it was sent.
    static func judge(responseRevision: Int, currentRevision: Int, lineStillUnchanged: Bool) -> Outcome {
        if responseRevision >= currentRevision { return .accept }
        if lineStillUnchanged { return .accept }
        return .discard(reason: "response is for drawing revision \(responseRevision) but the page is now at \(currentRevision), and the named line changed")
    }
}
