import XCTest
@testable import PencilTutor

/// The tutor-memory state machine against a fake server: what is shown, what is sent, and when the consent screen is offered.
@MainActor
final class MemoryStoreTests: XCTestCase {
    private let version = "2026-11-14.1"

    /// A server stand-in that flips its own answer the way the real one does.
    final class FakeAPI: MemoryAPI {
        var status: MemoryStatusResponse
        var failStatus: Error?
        var failAct: Error?
        var acts: [MemoryActionRequest] = []
        var statusCalls = 0

        init(status: MemoryStatusResponse) { self.status = status }

        func memoryStatus() async throws -> MemoryStatusResponse {
            statusCalls += 1
            if let failStatus { throw failStatus }
            return status
        }

        func memoryAct(_ request: MemoryActionRequest) async throws -> MemoryActionResponse {
            acts.append(request)
            if let failAct { throw failAct }
            switch request.action {
            case "consent":
                status.consent = MemoryConsent(granted: true, current: true, givenBy: request.givenBy, recordedVia: "app", noticeVersion: request.noticeVersion ?? "?", at: "2026-11-14T18:00:00.000Z")
            case "withdraw":
                status.consent = MemoryConsent(granted: false, current: false, givenBy: nil, recordedVia: "app", noticeVersion: version, at: "2026-11-14T19:00:00.000Z")
                if request.erase == true { status.record = MemoryRecord(notes: 0, recent: []) }
            default:
                status.record = MemoryRecord(notes: 0, recent: [])
            }
            return MemoryActionResponse(ok: true, withdrawn: nil, deleted: nil, requestId: "t")
        }
    }

    private func notice() -> MemoryNotice {
        MemoryNotice(version: version, title: "Let the tutor remember?", intro: "i", sections: [MemoryNoticeSection(heading: "Why", body: "b")], policyUrl: "https://example.test/api/privacy")
    }

    private func status(feature: String = "on", consent: MemoryConsent? = nil, notes: Int = 0, recent: [MemoryRecentAttempt] = []) -> MemoryStatusResponse {
        MemoryStatusResponse(feature: feature, notice: notice(), consent: consent, record: MemoryRecord(notes: notes, recent: recent))
    }

    private func grant(current: Bool = true) -> MemoryConsent {
        MemoryConsent(granted: true, current: current, givenBy: "parent_guardian", recordedVia: "app", noticeVersion: current ? version : "2026-01-01.1", at: "2026-11-14T18:00:00.000Z")
    }

    private func makeStore(_ api: FakeAPI, code: String? = "ABCD2345") -> (MemoryStore, UserDefaults) {
        let suite = "memory-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (MemoryStore(api: api, log: SessionLog(), codeHash: { code.map(StudentCode.shortHash) }, defaults: defaults), defaults)
    }

    func testAServerWithoutMemoryShowsNothing() async {
        let api = FakeAPI(status: status())
        api.failStatus = TutorError.rejected(status: 404, reason: "not found")
        let (store, _) = makeStore(api)
        await store.refresh(reason: "test")
        XCTAssertFalse(store.isAvailable)
        XCTAssertFalse(store.shouldOffer)
    }

    func testOffWithNoRecordShowsNothing() async {
        let (store, _) = makeStore(FakeAPI(status: status(feature: "off")))
        await store.refresh(reason: "test")
        XCTAssertFalse(store.isAvailable)
        XCTAssertFalse(store.canTurnOn)
    }

    func testAnExistingRecordCanStillBeManagedWhenTheServerStopsOfferingMemory() async {
        let (store, _) = makeStore(FakeAPI(status: status(feature: "off", consent: grant(), notes: 1)))
        await store.refresh(reason: "test")
        XCTAssertTrue(store.isAvailable)
        XCTAssertTrue(store.isOn)
        XCTAssertFalse(store.canTurnOn, "no new agreements while the server does not offer memory")
        XCTAssertFalse(store.shouldOffer)
    }

    func testTurningOnSendsTheAttestationAndTheTextVersionShown() async {
        let api = FakeAPI(status: status())
        let (store, _) = makeStore(api)
        await store.refresh(reason: "test")
        XCTAssertFalse(store.isOn)
        let on = await store.turnOn(as: .adultStudent)
        XCTAssertTrue(on)
        XCTAssertEqual(api.acts, [MemoryActionRequest.consent(.adultStudent, version: version)])
        XCTAssertEqual(api.acts.first?.attested, true)
        XCTAssertTrue(store.isOn)
        XCTAssertTrue(store.statusLine.hasPrefix("On since"))
    }

    func testAChangedTextIsRefetchedNotAccepted() async {
        let api = FakeAPI(status: status())
        api.failAct = TutorError.rejected(status: 409, reason: "notice_outdated")
        let (store, _) = makeStore(api)
        await store.refresh(reason: "test")
        let calls = api.statusCalls
        let on = await store.turnOn(as: .parentGuardian)
        XCTAssertFalse(on)
        XCTAssertNotNil(store.message)
        XCTAssertGreaterThan(api.statusCalls, calls, "it asks the server for the new text")
    }

    func testTurnOffCanKeepOrEraseWhatIsStored() async {
        let recent = [MemoryRecentAttempt(problemId: "u3-04", looks: 3, asks: 0, interrupts: 1, lastAt: "2026-11-14T18:00:00.000Z")]
        let api = FakeAPI(status: status(consent: grant(), notes: 2, recent: recent))
        let (store, _) = makeStore(api)
        await store.refresh(reason: "test")
        _ = await store.turnOff(erase: false)
        XCTAssertEqual(api.acts.last, MemoryActionRequest.withdraw(erase: false))
        XCTAssertFalse(store.isOn)
        XCTAssertEqual(store.status?.record?.recent.count, 1, "kept")
        _ = await store.turnOff(erase: true)
        XCTAssertEqual(api.acts.last, MemoryActionRequest.withdraw(erase: true))
        XCTAssertEqual(store.status?.record?.recent.count, 0, "erased")
    }

    func testEraseAloneLeavesTheAgreementInPlace() async {
        let api = FakeAPI(status: status(consent: grant(), notes: 1))
        let (store, _) = makeStore(api)
        await store.refresh(reason: "test")
        _ = await store.erase()
        XCTAssertEqual(api.acts.last, MemoryActionRequest.erase)
        XCTAssertTrue(store.isOn)
        XCTAssertEqual(store.status?.record?.notes, 0)
    }

    func testAFailedActionSaysSoCalmlyAndChangesNothing() async {
        let api = FakeAPI(status: status(consent: grant()))
        api.failAct = TutorError.offline(detail: "x")
        let (store, _) = makeStore(api)
        await store.refresh(reason: "test")
        let done = await store.turnOff(erase: true)
        XCTAssertFalse(done)
        XCTAssertTrue(store.isOn)
        XCTAssertTrue(store.message?.contains("did not go through") ?? false)
    }

    func testTheConsentScreenIsOfferedOnceAndSkippingCountsAsSeen() async {
        let (store, _) = makeStore(FakeAPI(status: status()))
        await store.refresh(reason: "test")
        XCTAssertTrue(store.shouldOffer)
        store.markOffered()
        XCTAssertFalse(store.shouldOffer)
    }

    func testNoOfferWithoutACodeOrAfterAWithdrawal() async {
        let (noCode, _) = makeStore(FakeAPI(status: status()), code: nil)
        await noCode.refresh(reason: "test")
        XCTAssertFalse(noCode.shouldOffer)

        let withdrawn = MemoryConsent(granted: false, current: false, givenBy: nil, recordedVia: "app", noticeVersion: version, at: "2026-11-14T19:00:00.000Z")
        let (store, _) = makeStore(FakeAPI(status: status(consent: withdrawn)))
        await store.refresh(reason: "test")
        XCTAssertFalse(store.shouldOffer, "someone who said no is not asked again")
    }

    func testAnAgreementToOlderTextIsOfferedAgainAndMemoryIsOff() async {
        let (store, _) = makeStore(FakeAPI(status: status(consent: grant(current: false))))
        await store.refresh(reason: "test")
        XCTAssertFalse(store.isOn)
        XCTAssertTrue(store.shouldOffer)
        XCTAssertTrue(store.statusLine.contains("agreement again"))
    }

    func testTheServersJSONDecodesAndOurRequestsOmitUnusedFields() throws {
        let json = """
        {"feature":"on","notice":{"version":"2026-11-14.1","title":"T","intro":"i","sections":[{"heading":"h","body":"b"}],"policy_url":"https://x.test/api/privacy"},
         "consent":{"granted":true,"current":true,"given_by":"parent_guardian","recorded_via":"admin","notice_version":"2026-11-14.1","at":"2026-11-14T18:00:00.000Z"},
         "record":{"notes":2,"recent":[{"problem_id":"u3-04","looks":5,"asks":1,"interrupts":2,"last_at":"2026-11-14T18:00:00.000Z"}]},"request_id":"r"}
        """
        let decoded = try JSONDecoder().decode(MemoryStatusResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.notice?.policyUrl, "https://x.test/api/privacy")
        XCTAssertEqual(decoded.consent?.recordedVia, "admin")
        XCTAssertEqual(decoded.record?.recent.first?.interrupts, 2)

        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MemoryActionRequest.withdraw(erase: true))) as? [String: Any]
        XCTAssertEqual(body?["action"] as? String, "withdraw")
        XCTAssertEqual(body?["erase"] as? Bool, true)
        XCTAssertNil(body?["given_by"])
        let consent = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MemoryActionRequest.consent(.parentGuardian, version: "v"))) as? [String: Any]
        XCTAssertEqual(consent?["given_by"] as? String, "parent_guardian")
        XCTAssertEqual(consent?["attested"] as? Bool, true)
        XCTAssertEqual(consent?["notice_version"] as? String, "v")
    }
}
