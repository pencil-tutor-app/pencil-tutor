import Foundation

// The in-app subscription (plan amendment 20, docs/app-store.md). This file is the whole flow, written against small protocols so
// it is unit-tested without StoreKit or a network:  buy or restore -> send Apple's signed transaction to our server -> the server
// answers with a student code -> the code is stored exactly like a typed one (`StudentAccount.signIn`) -> only then is the
// transaction finished. If anything before that fails the transaction stays unfinished, and StoreKit hands it back on the next
// launch, so a paid student is never left without a code.
//
// Logging rule: the signed transaction and the code never reach the log. Labels, counts and `StudentCode.shortHash` only.

/// What the Subscribe button needs to show. Text comes from the App Store (localized price), never from us.
struct SubscriptionProduct: Equatable {
    let id: String
    let displayName: String
    let priceText: String
    /// "month" for a one month period, otherwise "3 months" and so on.
    let periodText: String
}

/// One StoreKit transaction, reduced to what the flow needs.
protocol StoreTransaction {
    var productID: String { get }
    /// Apple's signed (JWS) copy of the transaction. This is what the server verifies.
    var signedJWS: String { get }
    func finish() async
}

enum StoreOutcome {
    case purchased(StoreTransaction)
    case cancelled
    /// Waiting for approval (Ask to Buy, or a payment that has not cleared). The transaction arrives later through `updates()`.
    case pending
}

enum StoreFailure: Error, Equatable {
    case productNotFound
    /// StoreKit's own on-device check failed, so the transaction is not trusted and is not sent anywhere.
    case unverified
    case failed(detail: String)
}

protocol StoreGateway: AnyObject {
    func loadProduct(id: String) async throws -> SubscriptionProduct
    func purchase(productID: String) async throws -> StoreOutcome
    /// Asks the App Store to refresh what this Apple account owns (may ask the person to sign in).
    func syncWithAppStore() async throws
    /// Active, verified transactions for this product.
    func currentEntitlements(productID: String) async -> [StoreTransaction]
    /// Renewals, approved Ask to Buy purchases and transactions left unfinished by an earlier launch. Verified ones only.
    func updates() -> AsyncStream<StoreTransaction>
}

struct PurchaseReply: Decodable, Equatable {
    var code: String
    var created: Bool?
    var requestId: String?

    private enum CodingKeys: String, CodingKey {
        case code, created
        case requestId = "request_id"
    }
}

enum PurchaseError: Error, Equatable {
    case offline
    /// The server knows the transaction and it is over (expired or refunded). Nothing to retry.
    case notActive
    /// The server looked at it and said no (HTTP 4xx other than the above). Retrying the same thing will not help until something is fixed.
    case rejected(reason: String)
    /// The server or Apple's check was not available (HTTP 5xx). Worth another try.
    case unavailable(reason: String)
    case badReply

    var logLabel: String {
        switch self {
        case .offline: return "offline"
        case .notActive: return "not_active"
        case .rejected(let reason): return "rejected:\(reason)"
        case .unavailable(let reason): return "unavailable:\(reason)"
        case .badReply: return "bad_reply"
        }
    }
}

protocol PurchaseRedeeming {
    /// POST /api/purchase. No student code is needed; Apple's signature is the credential.
    func redeem(signedTransaction: String) async throws -> PurchaseReply
}

enum HeldCode: Equatable {
    case none
    case same
    case different
}

/// What the flow needs from `StudentAccount`.
@MainActor
protocol PurchaseAccount: AnyObject {
    func held(_ code: String) -> HeldCode
    /// Stores the code the way a typed one is stored. True when the server accepted it.
    func signIn(typed: String) async -> Bool
}

@MainActor
final class SubscriptionManager: ObservableObject {
    enum Availability: Equatable {
        case loading
        case available(SubscriptionProduct)
        case unavailable
    }

    enum Busy: Equatable {
        case idle
        case buying
        case restoring
    }

    @Published private(set) var availability: Availability = .loading
    @Published private(set) var busy: Busy = .idle
    /// Short plain text for the code screen. Nil when there is nothing to say.
    @Published private(set) var message: String?

    private let productID: String
    private let store: StoreGateway
    private let redeemer: PurchaseRedeeming
    private weak var account: PurchaseAccount?
    private let log: SessionLog
    private var listener: Task<Void, Never>?

    init(productID: String, store: StoreGateway, redeemer: PurchaseRedeeming, account: PurchaseAccount, log: SessionLog) {
        self.productID = productID
        self.store = store
        self.redeemer = redeemer
        self.account = account
        self.log = log
    }

    // MARK: - Words the student sees

    enum Words {
        static let pending = "Your purchase is waiting for approval. It will unlock when it goes through."
        static let notFinished = "We could not finish setting up your subscription. Check the internet and tap Restore Purchases."
        static let unverified = "The App Store could not confirm that purchase. Please try again."
        static let storeFailed = "The App Store is not answering right now. Please try again in a moment."
        static let nothingToRestore = "No subscription was found for this Apple account."
        static let unavailable = "Subscriptions are not available right now."
        static let ended = "That subscription has ended."
    }

    // MARK: - Starting up

    /// Loads the product and starts listening for renewals and unfinished purchases. Call once at launch.
    func start() {
        guard listener == nil else { return }
        let updates = store.updates()
        listener = Task { [weak self] in
            for await transaction in updates {
                guard let self else { return }
                await self.handleUpdate(transaction)
            }
        }
        log.record("iap_listener_started", ["product": productID])
        Task { await loadProduct() }
    }

    func loadProduct() async {
        do {
            let product = try await store.loadProduct(id: productID)
            availability = .available(product)
            log.record("iap_product_loaded", ["product": productID, "period": product.periodText])
        } catch {
            availability = .unavailable
            log.record("iap_product_failed", ["product": productID, "reason": Self.label(error)])
        }
    }

    // MARK: - Buying

    func subscribe() async {
        guard busy == .idle else { return }
        busy = .buying
        message = nil
        defer { busy = .idle }
        log.record("iap_subscribe_tapped", ["product": productID])
        do {
            switch try await store.purchase(productID: productID) {
            case .purchased(let transaction):
                log.record("iap_purchased", ["product": productID])
                let result = await redeemAndSignIn(transaction, source: "subscribe", mayReplaceCode: true)
                message = result.studentMessage
            case .cancelled:
                log.record("iap_cancelled", ["product": productID])
            case .pending:
                log.record("iap_pending", ["product": productID, "next": "transaction_update"])
                message = Words.pending
            }
        } catch let failure as StoreFailure {
            message = failure == .unverified ? Words.unverified : Words.storeFailed
            log.record("iap_purchase_failed", ["product": productID, "reason": Self.label(failure)])
        } catch {
            message = Words.storeFailed
            log.record("iap_purchase_failed", ["product": productID, "reason": Self.label(error)])
        }
    }

    // MARK: - Restoring (App Review requires this button)

    func restore() async {
        guard busy == .idle else { return }
        busy = .restoring
        message = nil
        defer { busy = .idle }
        log.record("iap_restore_tapped", ["product": productID])
        do {
            try await store.syncWithAppStore()
        } catch {
            // Not fatal: the entitlements below may already be current. The reason is logged either way.
            log.record("iap_sync_failed", ["reason": Self.label(error)])
        }
        let owned = await store.currentEntitlements(productID: productID)
        log.record("iap_restore_found", ["count": owned.count])
        guard !owned.isEmpty else {
            message = Words.nothingToRestore
            return
        }
        var last: Outcome = .failed
        for transaction in owned {
            last = await redeemAndSignIn(transaction, source: "restore", mayReplaceCode: true)
            if last == .signedIn { break }
        }
        message = last.studentMessage
    }

    // MARK: - Renewals and leftovers from an earlier launch

    private func handleUpdate(_ transaction: StoreTransaction) async {
        guard transaction.productID == productID else {
            log.record("iap_update_ignored", ["reason": "other_product"])
            await transaction.finish()
            return
        }
        log.record("iap_update_received", ["product": productID])
        // A background renewal never swaps out a code the student is using (they might be on a code they typed); it only
        // makes sure the server has the renewal and signs in when there is no code at all.
        let result = await redeemAndSignIn(transaction, source: "update", mayReplaceCode: false)
        // The student only needs to hear about a problem when they are looking at the code screen and nothing worked.
        if result == .signedIn { message = nil }
    }

    // MARK: - The flow

    enum Outcome: Equatable {
        /// The server gave a code, it works, it is stored, the transaction is finished.
        case signedIn
        /// The server recorded it; the student already uses another code, which was left alone. Finished.
        case recordedOnly
        /// The subscription is over. Finished (the server has the record).
        case ended
        /// Not confirmed. The transaction stays unfinished and comes back on the next launch.
        case failed

        var studentMessage: String? {
            switch self {
            case .signedIn, .recordedOnly: return nil
            case .ended: return Words.ended
            case .failed: return Words.notFinished
            }
        }
    }

    private func redeemAndSignIn(_ transaction: StoreTransaction, source: String, mayReplaceCode: Bool) async -> Outcome {
        let reply: PurchaseReply
        do {
            reply = try await redeemer.redeem(signedTransaction: transaction.signedJWS)
        } catch PurchaseError.notActive {
            log.record("iap_confirm_inactive", ["source": source, "next": "finish_nothing_to_unlock"])
            await transaction.finish()
            return .ended
        } catch {
            let reason = (error as? PurchaseError)?.logLabel ?? Self.label(error)
            log.record("iap_confirm_failed", ["source": source, "reason": reason, "next": "left_unfinished_retried_on_next_launch"])
            return .failed
        }

        let code = StudentCode.normalize(reply.code)
        guard StudentCode.isValid(code), let account else {
            log.record("iap_confirm_failed", ["source": source, "reason": account == nil ? "no_account" : "server_code_malformed", "next": "left_unfinished"])
            return .failed
        }
        let hash = StudentCode.shortHash(code)

        if !mayReplaceCode, account.held(code) == .different {
            log.record("iap_code_not_adopted", ["source": source, "code_hash": hash, "reason": "student_uses_another_code", "next": "finished"])
            await transaction.finish()
            return .recordedOnly
        }
        guard await account.signIn(typed: code) else {
            log.record("iap_code_not_accepted", ["source": source, "code_hash": hash, "next": "left_unfinished"])
            return .failed
        }
        await transaction.finish()
        log.record("iap_finished", ["source": source, "code_hash": hash, "created": reply.created ?? false])
        return .signedIn
    }

    private static func label(_ error: Error) -> String {
        if let failure = error as? StoreFailure {
            switch failure {
            case .productNotFound: return "product_not_found"
            case .unverified: return "unverified"
            case .failed(let detail): return "failed:\(detail)"
            }
        }
        return String(describing: type(of: error))
    }
}
