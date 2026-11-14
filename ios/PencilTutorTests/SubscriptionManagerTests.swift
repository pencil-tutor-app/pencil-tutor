import XCTest
@testable import PencilTutor

private final class FakeTransaction: StoreTransaction {
    let productID: String
    let signedJWS: String
    var events: [String]
    private(set) var finished = false

    init(productID: String = "penciltutor.monthly", signedJWS: String = "signed-by-apple", events: [String] = []) {
        self.productID = productID
        self.signedJWS = signedJWS
        self.events = events
    }

    func finish() async {
        finished = true
    }
}

private final class FakeStore: StoreGateway {
    var product: Result<SubscriptionProduct, Error> = .success(
        SubscriptionProduct(id: "penciltutor.monthly", displayName: "Pencil Tutor monthly", priceText: "CA$19.00", periodText: "month")
    )
    var outcome: Result<StoreOutcome, Error> = .success(.cancelled)
    var owned: [StoreTransaction] = []
    var syncFails = false
    private(set) var syncCalls = 0
    private var continuation: AsyncStream<StoreTransaction>.Continuation?

    func loadProduct(id: String) async throws -> SubscriptionProduct { try product.get() }
    func purchase(productID: String) async throws -> StoreOutcome { try outcome.get() }
    func syncWithAppStore() async throws {
        syncCalls += 1
        if syncFails { throw StoreFailure.failed(detail: "sync") }
    }
    func currentEntitlements(productID: String) async -> [StoreTransaction] { owned }
    func updates() -> AsyncStream<StoreTransaction> {
        AsyncStream { self.continuation = $0 }
    }
    func deliver(_ transaction: StoreTransaction) { continuation?.yield(transaction) }
}

private struct FakeRedeemer: PurchaseRedeeming {
    var result: Result<PurchaseReply, PurchaseError>
    func redeem(signedTransaction: String) async throws -> PurchaseReply { try result.get() }
}

@MainActor
private final class FakeAccount: PurchaseAccount {
    var holding: HeldCode = .none
    var accepts = true
    private(set) var signedInWith: [String] = []
    var onSignIn: (() -> Void)?

    func held(_ code: String) -> HeldCode { holding }
    func signIn(typed: String) async -> Bool {
        signedInWith.append(typed)
        onSignIn?()
        return accepts
    }
}

@MainActor
final class SubscriptionManagerTests: XCTestCase {
    private var directory: URL!
    private var log: SessionLog!
    private let code = "ABCDEFGH"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("iap-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = SessionLog(directory: directory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func reply(_ code: String? = nil) -> Result<PurchaseReply, PurchaseError> {
        .success(PurchaseReply(code: code ?? self.code, created: true, requestId: "r"))
    }

    private func make(store: FakeStore, redeem: Result<PurchaseReply, PurchaseError>? = nil, account: FakeAccount) -> SubscriptionManager {
        lastStore = store
        return SubscriptionManager(
            productID: "penciltutor.monthly", store: store,
            redeemer: FakeRedeemer(result: redeem ?? reply()), account: account, log: log
        )
    }

    // MARK: - Product

    func testTheProductLoadsOrTheSectionSaysItIsUnavailable() async {
        let store = FakeStore()
        let manager = make(store: store, account: FakeAccount())
        XCTAssertEqual(manager.availability, .loading)
        await manager.loadProduct()
        let expected = try! store.product.get()
        XCTAssertEqual(manager.availability, .available(expected))

        store.product = .failure(StoreFailure.productNotFound)
        await manager.loadProduct()
        XCTAssertEqual(manager.availability, .unavailable)
    }

    // MARK: - Buying

    func testABoughtSubscriptionIsStoredLikeATypedCodeAndOnlyThenFinished() async {
        let transaction = FakeTransaction()
        let store = FakeStore()
        store.outcome = .success(.purchased(transaction))
        let account = FakeAccount()
        account.onSignIn = { XCTAssertFalse(transaction.finished, "the transaction is finished only after the code is stored") }
        let manager = make(store: store, account: account)

        await manager.subscribe()

        XCTAssertEqual(account.signedInWith, [code], "the server's code goes through the same sign-in as a typed one")
        XCTAssertTrue(transaction.finished)
        XCTAssertNil(manager.message)
        XCTAssertEqual(manager.busy, .idle)
    }

    func testIfTheServerCannotConfirmTheTransactionStaysUnfinishedAndTheStudentIsToldPlainly() async {
        let offline = FakeTransaction()
        let store = FakeStore()
        store.outcome = .success(.purchased(offline))
        let account = FakeAccount()
        let manager = make(store: store, redeem: .failure(.offline), account: account)

        await manager.subscribe()

        XCTAssertFalse(offline.finished)
        XCTAssertTrue(account.signedInWith.isEmpty)
        XCTAssertEqual(manager.message, SubscriptionManager.Words.notFinished)
        XCTAssertEqual(manager.busy, .idle)
    }

    func testACodeTheServerAcceptedButTheAppCouldNotSignInWithIsNotFinished() async {
        let transaction = FakeTransaction()
        let store = FakeStore()
        store.outcome = .success(.purchased(transaction))
        let account = FakeAccount()
        account.accepts = false
        let manager = make(store: store, account: account)

        await manager.subscribe()

        XCTAssertFalse(transaction.finished)
        XCTAssertEqual(manager.message, SubscriptionManager.Words.notFinished)
    }

    func testAMalformedCodeFromTheServerIsRefused() async {
        let transaction = FakeTransaction()
        let store = FakeStore()
        store.outcome = .success(.purchased(transaction))
        let account = FakeAccount()
        let manager = make(store: store, redeem: reply("nope"), account: account)

        await manager.subscribe()

        XCTAssertFalse(transaction.finished)
        XCTAssertTrue(account.signedInWith.isEmpty)
    }

    func testCancellingSaysNothingAndPendingSaysItIsWaiting() async {
        let store = FakeStore()
        let manager = make(store: store, account: FakeAccount())

        store.outcome = .success(.cancelled)
        await manager.subscribe()
        XCTAssertNil(manager.message)

        store.outcome = .success(.pending)
        await manager.subscribe()
        XCTAssertEqual(manager.message, SubscriptionManager.Words.pending)
    }

    func testAnUnverifiedPurchaseIsNeverSentAnywhere() async {
        let store = FakeStore()
        store.outcome = .failure(StoreFailure.unverified)
        let account = FakeAccount()
        let manager = make(store: store, account: account)

        await manager.subscribe()

        XCTAssertEqual(manager.message, SubscriptionManager.Words.unverified)
        XCTAssertTrue(account.signedInWith.isEmpty)
    }

    // MARK: - Restoring

    func testRestoreWithNothingOwnedSaysSo() async {
        let store = FakeStore()
        let manager = make(store: store, account: FakeAccount())

        await manager.restore()

        XCTAssertEqual(store.syncCalls, 1)
        XCTAssertEqual(manager.message, SubscriptionManager.Words.nothingToRestore)
    }

    func testRestoreSignsInWithTheCodeForTheOwnedSubscriptionEvenIfTheStoreSyncFails() async {
        let owned = FakeTransaction()
        let store = FakeStore()
        store.owned = [owned]
        store.syncFails = true
        let account = FakeAccount()
        let manager = make(store: store, account: account)

        await manager.restore()

        XCTAssertEqual(account.signedInWith, [code])
        XCTAssertTrue(owned.finished)
        XCTAssertNil(manager.message)
    }

    // MARK: - Renewals and leftovers

    func testAnUpdateSignsInWhenThereIsNoCodeYet() async {
        let transaction = FakeTransaction()
        let account = FakeAccount()
        let manager = make(store: FakeStore(), account: account)

        await handle(transaction, with: manager)

        XCTAssertEqual(account.signedInWith, [code])
        XCTAssertTrue(transaction.finished)
    }

    func testAnUpdateNeverReplacesACodeTheStudentIsUsingButIsStillFinished() async {
        let transaction = FakeTransaction()
        let account = FakeAccount()
        account.holding = .different
        let manager = make(store: FakeStore(), account: account)

        await handle(transaction, with: manager)

        XCTAssertTrue(account.signedInWith.isEmpty)
        XCTAssertTrue(transaction.finished, "the server has the renewal recorded, so there is nothing left to retry")
    }

    func testAnEndedOrRefundedTransactionIsFinishedWithoutAnyCode() async {
        let transaction = FakeTransaction()
        let account = FakeAccount()
        let manager = make(store: FakeStore(), redeem: .failure(.notActive), account: account)

        await handle(transaction, with: manager)

        XCTAssertTrue(transaction.finished)
        XCTAssertTrue(account.signedInWith.isEmpty)
    }

    func testAServerThatIsDownLeavesAnUpdateUnfinishedForTheNextLaunch() async {
        let transaction = FakeTransaction()
        let manager = make(store: FakeStore(), redeem: .failure(.unavailable(reason: "database_unavailable")), account: FakeAccount())

        await handle(transaction, with: manager)

        XCTAssertFalse(transaction.finished)
    }

    func testAnotherProductIsFinishedAndIgnored() async {
        let transaction = FakeTransaction(productID: "something.else")
        let account = FakeAccount()
        let manager = make(store: FakeStore(), account: account)

        await handle(transaction, with: manager)

        XCTAssertTrue(transaction.finished)
        XCTAssertTrue(account.signedInWith.isEmpty)
    }

    /// Delivers a transaction through the same stream the real app listens to, then waits for it to be handled.
    private func handle(_ transaction: FakeTransaction, with manager: SubscriptionManager) async {
        manager.start()
        await Task.yield()
        lastStore?.deliver(transaction)
        // Give the listener time to run; a transaction that is meant to stay unfinished simply waits out the loop.
        for _ in 0..<40 where !transaction.finished {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// The store the most recent `make` built a manager around, so a test can push an update through it.
    private var lastStore: FakeStore?

    // MARK: - Words and server errors

    func testTheTermsLineIsTheAppStoresOwnPriceAndPeriod() {
        let monthly = SubscriptionProduct(id: "x", displayName: "x", priceText: "CA$19.00", periodText: "month")
        XCTAssertEqual(SubscribeSection.terms(for: monthly), "CA$19.00 per month. Renews automatically until you cancel in your Apple account settings.")
        let quarterly = SubscriptionProduct(id: "x", displayName: "x", priceText: "$50", periodText: "3 months")
        XCTAssertEqual(SubscribeSection.terms(for: quarterly), "$50 every 3 months. Renews automatically until you cancel in your Apple account settings.")
    }

    func testServerAnswersBecomePurchaseErrors() {
        func body(_ error: String, _ reason: String) -> ServerErrorBody { ServerErrorBody(error: error, reason: reason, allowance: nil) }
        XCTAssertEqual(HTTPPurchaseClient.error(status: 403, body: body("subscription_not_active", "this subscription has ended")), .notActive)
        XCTAssertEqual(HTTPPurchaseClient.error(status: 422, body: body("wrong_app", "bundle_id_mismatch")), .rejected(reason: "bundle_id_mismatch"))
        XCTAssertEqual(HTTPPurchaseClient.error(status: 503, body: body("iap_not_configured", "APPLE_BUNDLE_ID is not set")), .unavailable(reason: "APPLE_BUNDLE_ID is not set"))
        XCTAssertEqual(HTTPPurchaseClient.error(status: 500, body: nil), .unavailable(reason: "no reason given"))
    }
}
