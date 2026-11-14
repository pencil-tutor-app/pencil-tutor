import XCTest
@testable import PencilTutor

final class ActivityMeterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func decide(_ meter: ActivityMeter, at seconds: TimeInterval, open: Bool = true, foreground: Bool = true, blocked: Bool = false) -> ActivityMeter.Decision {
        meter.decide(now: t0.addingTimeInterval(seconds), problemOpen: open, inForeground: foreground, blocked: blocked)
    }

    func testTheConstantsAreTheServersTwoMinuteWindowAndAMinuteBeat() {
        XCTAssertEqual(ActivityMeter.activityWindow, 120)
        XCTAssertEqual(ActivityMeter.heartbeatInterval, 60)
    }

    func testNothingHappenedMeansNoHeartbeat() {
        XCTAssertEqual(decide(ActivityMeter(), at: 10), .skip(reason: .noRecentActivity))
    }

    func testRecentInkSendsAHeartbeat() {
        var meter = ActivityMeter()
        meter.note(.ink, at: t0)
        XCTAssertEqual(decide(meter, at: 30), .send(lastActivity: .ink, secondsAgo: 30))
    }

    func testActivityOlderThanTwoMinutesDoesNotCount() {
        var meter = ActivityMeter()
        meter.note(.ink, at: t0)
        XCTAssertEqual(decide(meter, at: 120), .send(lastActivity: .ink, secondsAgo: 120), "exactly two minutes still counts")
        XCTAssertEqual(decide(meter, at: 121), .skip(reason: .noRecentActivity))
    }

    func testAQuestionOrALookCountsAndTheLatestKindIsReported() {
        var meter = ActivityMeter()
        meter.note(.ink, at: t0)
        meter.note(.question, at: t0.addingTimeInterval(20))
        XCTAssertEqual(decide(meter, at: 50), .send(lastActivity: .question, secondsAgo: 30))
        meter.note(.look, at: t0.addingTimeInterval(55))
        XCTAssertEqual(decide(meter, at: 60), .send(lastActivity: .look, secondsAgo: 5))
    }

    func testNeverOnTheProblemListInTheBackgroundOrWhenBlocked() {
        var meter = ActivityMeter()
        meter.note(.ink, at: t0)
        XCTAssertEqual(decide(meter, at: 10, open: false), .skip(reason: .problemClosed))
        XCTAssertEqual(decide(meter, at: 10, foreground: false), .skip(reason: .background))
        XCTAssertEqual(decide(meter, at: 10, blocked: true), .skip(reason: .blocked))
        XCTAssertEqual(decide(meter, at: 10, open: false, foreground: false, blocked: true), .skip(reason: .problemClosed),
                       "the problem being closed is reported first")
    }

    func testTwoHeartbeatsNeverCloserThanFiftySeconds() {
        var meter = ActivityMeter()
        meter.note(.ink, at: t0)
        meter.noteHeartbeatSent(at: t0.addingTimeInterval(10))
        meter.note(.ink, at: t0.addingTimeInterval(50))
        XCTAssertEqual(decide(meter, at: 59), .skip(reason: .tooSoon))
        XCTAssertEqual(decide(meter, at: 60), .send(lastActivity: .ink, secondsAgo: 10))
    }

    func testAStudentWhoStopsWritingStopsBeingCounted() {
        var meter = ActivityMeter()
        meter.note(.ink, at: t0)
        var sent = 0
        var clock: TimeInterval = 0
        // A beat every minute for ten minutes, but the student wrote nothing after the first second.
        for _ in 0..<10 {
            clock += 60
            if case .send = decide(meter, at: clock) {
                sent += 1
                meter.noteHeartbeatSent(at: t0.addingTimeInterval(clock))
            }
        }
        XCTAssertEqual(sent, 2, "beats at 60 s and 120 s fall inside the two-minute window; later ones do not")
    }

    func testDecisionLabelsForTheLog() {
        XCTAssertEqual(ActivityMeter.Decision.send(lastActivity: .ink, secondsAgo: 3).label, "send_after_ink")
        XCTAssertEqual(ActivityMeter.Decision.skip(reason: .noRecentActivity).label, "skip_no_activity_in_2_min")
    }
}
