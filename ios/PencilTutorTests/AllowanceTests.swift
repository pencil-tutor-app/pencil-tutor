import XCTest
@testable import PencilTutor

final class AllowanceTests: XCTestCase {
    private func allowance(state: AllowanceState = .ok, notice: AllowanceNotice? = nil, minutes: Int = 100, month: String = "2026-11") -> Allowance {
        Allowance(month: month, usedSeconds: 0, capSeconds: 28_800, remainingSeconds: minutes * 60, remainingMinutes: minutes,
                  percentUsed: 10, state: state, notice: notice)
    }

    func testDecodesTheServerContract() throws {
        let json = #"{"month":"2026-11","used_seconds":120,"cap_seconds":28800,"remaining_seconds":28680,"remaining_minutes":478,"percent_used":0.4,"state":"ok","notice":null}"#
        let decoded = try JSONDecoder().decode(Allowance.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.month, "2026-11")
        XCTAssertEqual(decoded.usedSeconds, 120)
        XCTAssertEqual(decoded.capSeconds, 28_800)
        XCTAssertEqual(decoded.remainingMinutes, 478)
        XCTAssertEqual(decoded.state, .ok)
        XCTAssertNil(decoded.notice)
        XCTAssertEqual(decoded.chipText, "478 min left")
    }

    func testNoticesAndStatesFromTheServer() throws {
        let low = #"{"month":"2026-11","used_seconds":23040,"cap_seconds":28800,"remaining_seconds":5760,"remaining_minutes":96,"percent_used":80,"state":"low","notice":"low"}"#
        let decodedLow = try JSONDecoder().decode(Allowance.self, from: Data(low.utf8))
        XCTAssertEqual(decodedLow.state, .low)
        XCTAssertEqual(decodedLow.notice, .low)

        let used = #"{"month":"2026-11","used_seconds":28800,"cap_seconds":28800,"remaining_seconds":0,"remaining_minutes":0,"percent_used":100,"state":"used_up","notice":"used_up"}"#
        let decodedUsed = try JSONDecoder().decode(Allowance.self, from: Data(used.utf8))
        XCTAssertEqual(decodedUsed.state, .usedUp)
        XCTAssertEqual(decodedUsed.notice, .usedUp)
        XCTAssertEqual(decodedUsed.chipText, "Hours used up")
    }

    func testUnknownWordsFromANewerServerDoNotBreakTheReply() throws {
        let json = #"{"month":"2026-11","used_seconds":0,"cap_seconds":28800,"remaining_seconds":28800,"remaining_minutes":480,"percent_used":0,"state":"mystery","notice":"something_new"}"#
        let decoded = try JSONDecoder().decode(Allowance.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.state, .ok, "an unknown state is treated as ok, not an error")
        XCTAssertNil(decoded.notice, "an unknown notice is never spoken")
    }

    func testMeAndHeartbeatReplies() throws {
        let me = #"{"plan":{"live":false,"cap_minutes":480},"allowance":{"month":"2026-11","used_seconds":0,"cap_seconds":28800,"remaining_seconds":28800,"remaining_minutes":480,"percent_used":0,"state":"ok","notice":null},"request_id":"r1"}"#
        let decodedMe = try JSONDecoder().decode(MeResponse.self, from: Data(me.utf8))
        XCTAssertFalse(decodedMe.plan.live)
        XCTAssertEqual(decodedMe.plan.capMinutes, 480)
        XCTAssertEqual(decodedMe.requestId, "r1")

        let beat = #"{"ok":true,"allowance":{"month":"2026-11","used_seconds":120,"cap_seconds":28800,"remaining_seconds":28680,"remaining_minutes":478,"percent_used":0.4,"state":"ok","notice":null},"request_id":"r2"}"#
        let decodedBeat = try JSONDecoder().decode(HeartbeatResponse.self, from: Data(beat.utf8))
        XCTAssertTrue(decodedBeat.ok)
        XCTAssertEqual(decodedBeat.allowance.remainingMinutes, 478)

        let request = try JSONEncoder().encode(HeartbeatRequest(sessionId: "s1", problemId: "u3-04"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["session_id", "problem_id"])

        let reporting = try JSONEncoder().encode(HeartbeatRequest(sessionId: "s1", problemId: "u3-04", secondsSinceActivity: 12))
        let reportingObject = try XCTUnwrap(JSONSerialization.jsonObject(with: reporting) as? [String: Any])
        XCTAssertEqual(reportingObject["seconds_since_activity"] as? Int, 12)
    }

    // MARK: - The 80% and 100% rules

    func testLowNoticeSpeaksTheMinutesLeftOnce() {
        let first = AllowanceDecision.decide(
            previous: allowance(), new: allowance(state: .low, notice: .low, minutes: 96),
            lowAnnouncedMonth: nil, currentlyUsedUp: false
        )
        XCTAssertEqual(first.speakLow, 96)
        XCTAssertFalse(first.enterUsedUp)

        let again = AllowanceDecision.decide(
            previous: allowance(state: .low), new: allowance(state: .low, notice: .low, minutes: 90),
            lowAnnouncedMonth: "2026-11", currentlyUsedUp: false
        )
        XCTAssertNil(again.speakLow, "already said this month in this launch")

        let nextMonth = AllowanceDecision.decide(
            previous: nil, new: allowance(state: .low, notice: .low, minutes: 90, month: "2026-12"),
            lowAnnouncedMonth: "2026-11", currentlyUsedUp: false
        )
        XCTAssertEqual(nextMonth.speakLow, 90)

        let noNotice = AllowanceDecision.decide(
            previous: allowance(), new: allowance(state: .low, notice: nil, minutes: 90),
            lowAnnouncedMonth: nil, currentlyUsedUp: false
        )
        XCTAssertNil(noNotice.speakLow, "state low without a notice is not spoken: the server decides when")
    }

    func testUsedUpEntersTheBlockedModeFromTheNoticeOrFromTheState() {
        let byNotice = AllowanceDecision.decide(
            previous: allowance(), new: allowance(state: .usedUp, notice: .usedUp, minutes: 0),
            lowAnnouncedMonth: nil, currentlyUsedUp: false
        )
        XCTAssertTrue(byNotice.enterUsedUp)
        XCTAssertNil(byNotice.speakLow, "no 80% line when the hours are gone")

        let byState = AllowanceDecision.decide(
            previous: nil, new: allowance(state: .usedUp, notice: nil, minutes: 0),
            lowAnnouncedMonth: nil, currentlyUsedUp: false
        )
        XCTAssertTrue(byState.enterUsedUp)
    }

    func testHoursComingBackClearTheBlock() {
        let back = AllowanceDecision.decide(
            previous: allowance(state: .usedUp), new: allowance(state: .ok, minutes: 480),
            lowAnnouncedMonth: nil, currentlyUsedUp: true
        )
        XCTAssertTrue(back.clearUsedUp)
        XCTAssertFalse(back.enterUsedUp)

        let neverBlocked = AllowanceDecision.decide(
            previous: allowance(), new: allowance(), lowAnnouncedMonth: nil, currentlyUsedUp: false
        )
        XCTAssertFalse(neverBlocked.clearUsedUp)
    }

    func testSpokenNoticesCarryThePurposeLabelAndPlainFallbackText() {
        XCTAssertEqual(SpokenNotice.low(minutes: 96).purpose, "allowance_low")
        XCTAssertEqual(SpokenNotice.usedUp.purpose, "allowance_used_up")
        XCTAssertEqual(SpokenNotice.low(minutes: 96).fallbackText, "You have about 96 minutes left this month.")
        XCTAssertEqual(SpokenNotice.low(minutes: 1).fallbackText, "You have about 1 minute left this month.")
        XCTAssertEqual(SpokenNotice.usedUp.fallbackText, "This month's tutoring hours are used up. Ask Edward for more time.")
    }

    // MARK: - Server refusals become typed errors

    func testServerRefusalsMapToTypedErrors() {
        func detail(_ status: Int, _ error: String?, _ reason: String? = nil, allowance: Allowance? = nil) -> String {
            HTTPTutorClient.error(status: status, body: ServerErrorBody(error: error, reason: reason, allowance: allowance)).logDetail
        }
        XCTAssertEqual(detail(401, "unauthorized", "unknown_code"), "unauthorized (HTTP 401): unknown_code")
        XCTAssertEqual(detail(401, "unauthorized", "malformed_code"), "unauthorized (HTTP 401): malformed_code")
        XCTAssertEqual(detail(403, "code_disabled"), "code_disabled (HTTP 403)")
        XCTAssertEqual(detail(403, "hours_used_up", allowance: allowance(state: .usedUp, minutes: 0)), "hours_used_up (HTTP 403)")
        XCTAssertEqual(detail(403, "live_not_in_plan"), "live_not_in_plan (HTTP 403)")
        XCTAssertEqual(detail(403, "something_else", "why"), "rejected HTTP 403: why")
        XCTAssertEqual(detail(503, "database_unavailable", "db"), "server_unavailable HTTP 503: db")
        XCTAssertEqual(detail(502, "model_error", "provider_http_500"), "server_unavailable HTTP 502: provider_http_500")
        XCTAssertEqual(detail(422, "invalid_request", "bad"), "rejected HTTP 422: bad")
    }

    func testUsedUpRefusalCarriesTheAllowanceTheServerSent() {
        let sent = allowance(state: .usedUp, minutes: 0)
        guard case .hoursUsedUp(let carried) = HTTPTutorClient.error(
            status: 403, body: ServerErrorBody(error: "hours_used_up", reason: "x", allowance: sent)
        ) else { return XCTFail("expected hoursUsedUp") }
        XCTAssertEqual(carried, sent)
    }

    func testStudentMessagesArePlainWords() {
        XCTAssertEqual(TutorError.unauthorized(reason: "unknown_code").studentMessage, "That code did not work. Check it and try again.")
        XCTAssertEqual(TutorError.codeTurnedOff.studentMessage, "This code has been turned off. Ask Edward.")
        XCTAssertEqual(TutorError.hoursUsedUp(allowance: nil).studentMessage, "This month's tutoring hours are used up. Ask Edward for more time.")
        for error in [TutorError.unauthorized(reason: "x"), .codeTurnedOff, .hoursUsedUp(allowance: nil), .liveNotInPlan, .recordingTooShort] {
            let text = error.studentMessage.lowercased()
            XCTAssertFalse(text.contains("http"), text)
            XCTAssertFalse(text.contains("401") || text.contains("403"), text)
            XCTAssertFalse(text.contains("token"), text)
        }
    }
}
