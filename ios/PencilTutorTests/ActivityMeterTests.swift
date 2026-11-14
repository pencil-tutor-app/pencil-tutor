import XCTest
@testable import PencilTutor

final class ActivityMeterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func decide(_ meter: ActivityMeter, at seconds: TimeInterval, open: Bool = true, foreground: Bool = true, blocked: Bool = false) -> ActivityMeter.Decision {
        meter.decide(now: t0.addingTimeInterval(seconds), problemOpen: open, inForeground: foreground, blocked: blocked)
    }

    func testTheBeatIsThirtySecondsSoSteadyWritingStaysInsideTheServersSixtySecondGap() {
        XCTAssertEqual(ActivityMeter.heartbeatInterval, 30)
        XCTAssertLessThan(ActivityMeter.heartbeatInterval * 2, 61)
    }

    func testNothingHappenedMeansNoHeartbeat() {
        XCTAssertEqual(decide(ActivityMeter(), at: 10), .skip(reason: .noNewActivity))
    }

    func testRecentInkSendsAHeartbeatCarryingHowLongAgoItWas() {
        var meter = ActivityMeter()
        meter.note(.ink, at: t0)
        XCTAssertEqual(decide(meter, at: 30), .send(lastActivity: .ink, secondsAgo: 30))
    }

    func testActivityThatWasAlreadyReportedIsNotReportedAgain() {
        var meter = ActivityMeter()
        meter.note(.ink, at: t0)
        meter.noteHeartbeatSent(at: t0.addingTimeInterval(30))
        XCTAssertEqual(decide(meter, at: 60), .skip(reason: .noNewActivity), "an iPad left on the table sends nothing")
        XCTAssertEqual(decide(meter, at: 600), .skip(reason: .noNewActivity))
        meter.note(.ink, at: t0.addingTimeInterval(70))
        XCTAssertEqual(decide(meter, at: 90), .send(lastActivity: .ink, secondsAgo: 20))
    }

    func testAFailedBeatReportsTheSameActivityAgain() {
        var meter = ActivityMeter()
        meter.note(.ink, at: t0)
        meter.noteHeartbeatSent(at: t0.addingTimeInterval(30))
        meter.noteHeartbeatFailed()
        XCTAssertEqual(decide(meter, at: 60), .send(lastActivity: .ink, secondsAgo: 60))
    }

    func testActivityOlderThanFiveMinutesIsNotReported() {
        var meter = ActivityMeter()
        meter.note(.ink, at: t0)
        XCTAssertEqual(decide(meter, at: 300), .send(lastActivity: .ink, secondsAgo: 300))
        XCTAssertEqual(decide(meter, at: 301), .skip(reason: .staleActivity))
    }

    func testTheLatestMomentWinsAndAnOlderOneArrivingLateIsIgnored() {
        var meter = ActivityMeter()
        meter.note(.ink, at: t0)
        meter.note(.question, at: t0.addingTimeInterval(20))
        XCTAssertEqual(decide(meter, at: 50), .send(lastActivity: .question, secondsAgo: 30))
        meter.note(.speech, at: t0.addingTimeInterval(55))
        XCTAssertEqual(decide(meter, at: 60), .send(lastActivity: .speech, secondsAgo: 5))
        meter.note(.look, at: t0.addingTimeInterval(40))
        XCTAssertEqual(decide(meter, at: 60), .send(lastActivity: .speech, secondsAgo: 5), "a moment older than the one held is ignored")
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

    func testTwoHeartbeatsNeverCloserThanTwentyFiveSeconds() {
        var meter = ActivityMeter()
        meter.note(.ink, at: t0)
        meter.noteHeartbeatSent(at: t0.addingTimeInterval(10))
        meter.note(.ink, at: t0.addingTimeInterval(20))
        XCTAssertEqual(decide(meter, at: 34), .skip(reason: .tooSoon))
        XCTAssertEqual(decide(meter, at: 35), .send(lastActivity: .ink, secondsAgo: 15))
    }

    func testAStudentWhoStopsWritingStopsSendingAnything() {
        var meter = ActivityMeter()
        meter.note(.ink, at: t0)
        var sent = 0
        var clock: TimeInterval = 0
        // A tick every 30 s for ten minutes, but the student wrote nothing after the first second.
        for _ in 0..<20 {
            clock += 30
            if case .send = decide(meter, at: clock) {
                sent += 1
                meter.noteHeartbeatSent(at: t0.addingTimeInterval(clock))
            }
        }
        XCTAssertEqual(sent, 1, "the one moment is reported once; after that every tick is silent")
    }

    func testDecisionLabelsForTheLog() {
        XCTAssertEqual(ActivityMeter.Decision.send(lastActivity: .ink, secondsAgo: 3).label, "send_after_ink")
        XCTAssertEqual(ActivityMeter.Decision.skip(reason: .noNewActivity).label, "skip_no_new_activity")
    }
}
