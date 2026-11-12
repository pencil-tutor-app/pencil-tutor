import XCTest
@testable import PencilTutor

final class LookPolicyTests: XCTestCase {
    private let policy = LookPolicy(idleSeconds: 2.5, cooldownSeconds: 45)
    private let t0 = Date(timeIntervalSinceReferenceDate: 5_000)

    private func evaluate(
        now: Double,
        lastInk: Double? = 0,
        revision: Int = 3,
        lastLook: Int = 2,
        lastInterruption: Double? = nil,
        inFlight: Bool = false,
        penDown: Bool = false
    ) -> LookPolicy.Verdict {
        policy.evaluate(
            now: t0.addingTimeInterval(now),
            lastInkAt: lastInk.map { t0.addingTimeInterval($0) },
            drawingRevision: revision,
            lastLookRevision: lastLook,
            lastInterruptionAt: lastInterruption.map { t0.addingTimeInterval($0) },
            requestInFlight: inFlight,
            penDown: penDown
        )
    }

    func testDefaultsAreTheDocumentedStartingValues() {
        XCTAssertEqual(TutorSettings.startingIdleSeconds, 2.5)
        XCTAssertEqual(TutorSettings.startingCooldownSeconds, 45)
        let settings = TutorSettings(defaults: UserDefaults(suiteName: "LookPolicyTests.defaults")!, useStartingDefaultsOnly: true)
        XCTAssertEqual(settings.policy, LookPolicy(idleSeconds: 2.5, cooldownSeconds: 45))
    }

    func testWaitsUntilThePenHasBeenIdleLongEnough() {
        XCTAssertEqual(evaluate(now: 1.0), .waitUntil(t0.addingTimeInterval(2.5), reason: "waiting for pen to be idle"))
    }

    func testLooksOnceIdleTimeHasPassed() {
        XCTAssertEqual(evaluate(now: 2.5), .lookNow)
        XCTAssertEqual(evaluate(now: 10), .lookNow)
    }

    func testDoesNotLookWhenDrawingIsUnchangedSinceLastLook() {
        XCTAssertEqual(evaluate(now: 10, revision: 2, lastLook: 2), .skip(reason: "drawing unchanged since last look"))
    }

    func testOneRequestAtATime() {
        XCTAssertEqual(evaluate(now: 10, inFlight: true), .skip(reason: "request already in flight"))
    }

    func testDoesNotLookWhilePenIsDown() {
        XCTAssertEqual(evaluate(now: 10, penDown: true), .skip(reason: "pen is down"))
    }

    func testNothingToLookAtWithoutInk() {
        XCTAssertEqual(evaluate(now: 10, lastInk: nil), .skip(reason: "no ink yet"))
    }

    func testNeverLooksWithin45SecondsOfAnInterruption() {
        // Interrupted at t=100; the student keeps writing and is idle again by t=110.
        XCTAssertEqual(
            evaluate(now: 115, lastInk: 110, lastInterruption: 100),
            .waitUntil(t0.addingTimeInterval(145), reason: "cooldown after interruption")
        )
        XCTAssertEqual(evaluate(now: 144.9, lastInk: 110, lastInterruption: 100),
                       .waitUntil(t0.addingTimeInterval(145), reason: "cooldown after interruption"))
        XCTAssertEqual(evaluate(now: 145, lastInk: 110, lastInterruption: 100), .lookNow)
    }

    func testCooldownHasNoEffectOnceItIsOver() {
        XCTAssertEqual(evaluate(now: 200, lastInk: 150, lastInterruption: 100), .lookNow)
    }

    func testStaleResponseIsAcceptedWhenTheDrawingHasNotMovedOn() {
        XCTAssertEqual(StaleResponseGate.judge(responseRevision: 7, currentRevision: 7, lineStillUnchanged: false), .accept)
    }

    func testStaleResponseIsDiscardedWhenDrawingMovedOnAndLineChanged() {
        let outcome = StaleResponseGate.judge(responseRevision: 7, currentRevision: 9, lineStillUnchanged: false)
        guard case .discard(let reason) = outcome else { return XCTFail("expected a discard, got \(outcome)") }
        XCTAssertTrue(reason.contains("7") && reason.contains("9"))
    }

    func testStaleResponseIsAcceptedWhenDrawingMovedOnButTheNamedLineIsUnchanged() {
        XCTAssertEqual(StaleResponseGate.judge(responseRevision: 7, currentRevision: 9, lineStillUnchanged: true), .accept)
    }
}
