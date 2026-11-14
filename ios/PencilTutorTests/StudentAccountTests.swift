import XCTest
@testable import PencilTutor

@MainActor
final class StudentAccountTests: XCTestCase {
    private var directory: URL!
    private var log: SessionLog!
    private var store: InMemoryStudentCodeStore!
    private var holder: StudentCodeHolder!
    private var announced: [SpokenNotice] = []
    private var meCalls = 0

    private let code = "ABCDEFGH"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("account-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = SessionLog(directory: directory)
        store = InMemoryStudentCodeStore()
        holder = StudentCodeHolder()
        announced = []
        meCalls = 0
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func allowance(state: AllowanceState = .ok, notice: AllowanceNotice? = nil, minutes: Int = 478, month: String = "2026-11") -> Allowance {
        Allowance(month: month, usedSeconds: 0, capSeconds: 28_800, remainingSeconds: minutes * 60, remainingMinutes: minutes,
                  percentUsed: 1, state: state, notice: notice)
    }

    private func me(live: Bool = false, state: AllowanceState = .ok) -> MeResponse {
        MeResponse(plan: PlanInfo(live: live, capMinutes: 480), allowance: allowance(state: state), requestId: "r")
    }

    private func makeAccount(fetch: @escaping () async throws -> MeResponse) -> StudentAccount {
        let account = StudentAccount(store: store, holder: holder, log: log, fetchMe: { [unowned self] in
            self.meCalls += 1
            return try await fetch()
        })
        account.announce = { [unowned self] notice in self.announced.append(notice) }
        return account
    }

    // MARK: - Launch

    func testAStoredCodeMeansReadyAndNoCodeMeansTheCodeScreen() {
        XCTAssertEqual(makeAccount(fetch: { self.me() }).phase, .needsCode)

        try? store.save(code)
        let ready = makeAccount(fetch: { self.me() })
        XCTAssertEqual(ready.phase, .ready)
        XCTAssertEqual(holder.current, code)
    }

    func testAStoredValueThatIsNotACodeIsDiscarded() {
        try? store.save("not a code")
        let account = makeAccount(fetch: { self.me() })
        XCTAssertEqual(account.phase, .needsCode)
        XCTAssertNil(store.load())
        XCTAssertNil(holder.current)
    }

    // MARK: - Signing in

    func testATypedCodeInTheWrongShapeNeverReachesTheServer() async {
        let account = makeAccount(fetch: { self.me() })
        await account.signIn(typed: "ABC")
        XCTAssertEqual(meCalls, 0)
        XCTAssertEqual(account.codeMessage, "Your code has 8 letters and numbers. Check it and try again.")
        await account.signIn(typed: "ABCDEFG0")
        XCTAssertEqual(meCalls, 0)
        XCTAssertEqual(account.codeMessage, "Codes never use the letters I, L, O or U, or the numbers 0 and 1. Check your code and try again.")
        XCTAssertNil(store.load())
        XCTAssertEqual(account.phase, .needsCode)
    }

    func testAGoodCodeIsCheckedKeptAndOpensTheApp() async {
        let account = makeAccount(fetch: { self.me(live: true) })
        await account.signIn(typed: "abcd-efgh")
        XCTAssertEqual(meCalls, 1)
        XCTAssertEqual(account.phase, .ready)
        XCTAssertEqual(store.load(), code)
        XCTAssertEqual(holder.current, code)
        XCTAssertEqual(account.plan?.live, true)
        XCTAssertTrue(account.liveAllowed)
        XCTAssertEqual(account.allowance?.remainingMinutes, 478)
        XCTAssertNil(account.codeMessage)
        XCTAssertFalse(account.isChecking)
        XCTAssertEqual(account.maskedCode, "ABCD-••••")
    }

    func testAWrongCodeShowsFriendlyTextAndKeepsNothing() async {
        let account = makeAccount(fetch: { throw TutorError.unauthorized(reason: "unknown_code") })
        await account.signIn(typed: code)
        XCTAssertEqual(account.codeMessage, "That code did not work. Check it and try again.")
        XCTAssertEqual(account.phase, .needsCode)
        XCTAssertNil(store.load())
        XCTAssertNil(holder.current, "the code that failed is not left in use")
    }

    func testNoInternetOnTheCodeScreenSaysSoInPlainWords() async {
        let account = makeAccount(fetch: { throw TutorError.offline(detail: "x") })
        await account.signIn(typed: code)
        XCTAssertEqual(account.codeMessage, "I can't reach the tutor. Check the internet and try again.")
        XCTAssertEqual(account.phase, .needsCode)
        XCTAssertNil(store.load())
    }

    func testATurnedOffCodeIsSaidPlainly() async {
        let account = makeAccount(fetch: { throw TutorError.codeTurnedOff })
        await account.signIn(typed: code)
        XCTAssertEqual(account.codeMessage, "This code has been turned off. Ask Edward.")
        XCTAssertEqual(account.phase, .needsCode)
    }

    func testAKeychainFailureStillLetsTheStudentIn() async {
        store.failsToSave = true
        let account = makeAccount(fetch: { self.me() })
        await account.signIn(typed: code)
        XCTAssertEqual(account.phase, .ready, "works for this launch")
        XCTAssertEqual(holder.current, code)
        XCTAssertNil(store.load())
    }

    func testSigningOutForgetsEverything() async {
        let account = makeAccount(fetch: { self.me(live: true) })
        await account.signIn(typed: code)
        account.signOut(reason: "test")
        XCTAssertEqual(account.phase, .needsCode)
        XCTAssertNil(store.load())
        XCTAssertNil(holder.current)
        XCTAssertNil(account.plan)
        XCTAssertNil(account.allowance)
        XCTAssertFalse(account.liveAllowed)
    }

    // MARK: - The server says the code is wrong later on

    func testAnUnknownCodeFromALaterRequestClearsTheKeychain() {
        try? store.save(code)
        let account = makeAccount(fetch: { self.me() })
        account.handle(serverError: .unauthorized(reason: "unknown_code"))
        XCTAssertEqual(account.phase, .needsCode)
        XCTAssertNil(store.load())
        XCTAssertEqual(account.codeMessage, "That code did not work. Check it and try again.")
    }

    func testOtherUnauthorizedReasonsShowTheCodeScreenButKeepTheStoredCode() {
        try? store.save(code)
        let account = makeAccount(fetch: { self.me() })
        account.handle(serverError: .unauthorized(reason: "bad_scheme"))
        XCTAssertEqual(account.phase, .needsCode)
        XCTAssertEqual(store.load(), code)
    }

    // MARK: - Hours

    func testTheEightyPercentLineIsSpokenOncePerMonth() {
        let account = makeAccount(fetch: { self.me() })
        account.apply(allowance: allowance(state: .low, notice: .low, minutes: 96), source: "test")
        XCTAssertEqual(announced, [.low(minutes: 96)])
        account.apply(allowance: allowance(state: .low, notice: .low, minutes: 90), source: "test")
        XCTAssertEqual(announced, [.low(minutes: 96)], "the same month is not announced twice")
        XCTAssertFalse(account.isBlocked)
        XCTAssertEqual(account.allowance?.chipText, "90 min left")
    }

    func testUsedUpBlocksAtOnceButTheLineWaitsForAnOpenProblemAndIsSaidOnce() {
        let account = makeAccount(fetch: { self.me() })
        account.apply(allowance: allowance(state: .usedUp, notice: .usedUp, minutes: 0), source: "test")
        XCTAssertEqual(account.block, .hoursUsedUp)
        XCTAssertTrue(account.isBlocked)
        XCTAssertEqual(announced, [], "not said out of nowhere on the problem list")

        account.problemOpened()
        XCTAssertEqual(announced, [.usedUp])
        account.problemOpened()
        account.apply(allowance: allowance(state: .usedUp, minutes: 0), source: "test")
        XCTAssertEqual(announced, [.usedUp], "once per app launch")
    }

    func testUsedUpFoundWhileAProblemIsOpenIsSaidImmediately() {
        let account = makeAccount(fetch: { self.me() })
        account.problemOpened()
        account.handle(serverError: .hoursUsedUp(allowance: allowance(state: .usedUp, minutes: 0)))
        XCTAssertEqual(account.block, .hoursUsedUp)
        XCTAssertEqual(announced, [.usedUp])
    }

    func testARefusalWithNoAllowanceStillBlocks() {
        let account = makeAccount(fetch: { self.me() })
        account.handle(serverError: .hoursUsedUp(allowance: nil))
        XCTAssertEqual(account.block, .hoursUsedUp)
    }

    func testHoursComingBackLiftTheBlock() {
        let account = makeAccount(fetch: { self.me() })
        account.apply(allowance: allowance(state: .usedUp, notice: .usedUp, minutes: 0), source: "test")
        XCTAssertTrue(account.isBlocked)
        account.apply(allowance: allowance(state: .ok, minutes: 480, month: "2026-12"), source: "test")
        XCTAssertFalse(account.isBlocked)
    }

    func testATurnedOffCodeBlocksWithoutSpeaking() {
        let account = makeAccount(fetch: { self.me() })
        account.problemOpened()
        account.handle(serverError: .codeTurnedOff)
        XCTAssertEqual(account.block, .codeTurnedOff)
        XCTAssertEqual(account.block?.message, "This code has been turned off. Ask Edward.")
        XCTAssertEqual(announced, [])
    }

    // MARK: - Asking the server

    func testRefreshLearnsThePlanAndCallsTogetherShareOneRequest() async {
        try? store.save(code)
        let account = makeAccount(fetch: {
            try await Task.sleep(nanoseconds: 80_000_000)
            return self.me(live: true)
        })
        async let first: Void = account.refresh(reason: "a")
        async let second: Void = account.refresh(reason: "b")
        _ = await (first, second)
        XCTAssertEqual(meCalls, 1)
        XCTAssertTrue(account.liveAllowed)
    }

    func testRefreshWithoutACodeDoesNotCallTheServer() async {
        let account = makeAccount(fetch: { self.me() })
        await account.refresh(reason: "test")
        XCTAssertEqual(meCalls, 0)
    }

    func testAFailedRefreshKeepsTheCodeAndTheBasePlan() async {
        try? store.save(code)
        let account = makeAccount(fetch: { throw TutorError.serverUnavailable(status: 503, reason: "database_unavailable") })
        await account.refresh(reason: "test")
        XCTAssertEqual(account.phase, .ready)
        XCTAssertEqual(store.load(), code)
        XCTAssertFalse(account.liveAllowed, "an unknown plan is the base plan: no live voice")
    }

    func testRefreshThatFindsAnUnknownCodeShowsTheCodeScreen() async {
        try? store.save(code)
        let account = makeAccount(fetch: { throw TutorError.unauthorized(reason: "unknown_code") })
        await account.refresh(reason: "launch")
        XCTAssertEqual(account.phase, .needsCode)
        XCTAssertNil(store.load())
    }

    // MARK: - Logging

    func testTheLogNeverHoldsTheCodeOnlyItsShortHash() async throws {
        let account = makeAccount(fetch: { self.me() })
        await account.signIn(typed: code)
        account.signOut(reason: "test")
        let exported = try XCTUnwrap(log.exportURL())
        let text = try String(contentsOf: exported, encoding: .utf8)
        XCTAssertFalse(text.contains(code), "the code itself must never be logged")
        XCTAssertTrue(text.contains(StudentCode.shortHash(code)), "its short hash is logged")
        XCTAssertTrue(text.contains("code_accepted"))
        XCTAssertTrue(text.contains("student_code_cleared"))
    }
}
