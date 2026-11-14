import Foundation
import StoreKit

/// One verified StoreKit 2 transaction. `signedJWS` is Apple's signed copy, the thing our server checks.
struct StoreKitTransaction: StoreTransaction {
    let transaction: Transaction
    let signedJWS: String

    var productID: String { transaction.productID }

    func finish() async {
        await transaction.finish()
    }
}

/// The real StoreKit 2 side. Everything on-device that touches Apple's frameworks is here and nowhere else.
///
/// Nothing is granted from the on-device check alone: a `.verified` result only means StoreKit trusts the transaction enough to
/// forward it. The server verifies Apple's signature again before it returns a code (server/lib/app-store.ts).
final class StoreKitGateway: StoreGateway {
    private let log: SessionLog
    private var products: [String: Product] = [:]

    init(log: SessionLog) {
        self.log = log
    }

    func loadProduct(id: String) async throws -> SubscriptionProduct {
        let found: [Product]
        do {
            found = try await Product.products(for: [id])
        } catch {
            throw StoreFailure.failed(detail: String(describing: type(of: error)))
        }
        guard let product = found.first else { throw StoreFailure.productNotFound }
        products[id] = product
        return SubscriptionProduct(
            id: product.id,
            displayName: product.displayName,
            priceText: product.displayPrice,
            periodText: Self.periodText(product.subscription?.subscriptionPeriod)
        )
    }

    func purchase(productID: String) async throws -> StoreOutcome {
        if products[productID] == nil { _ = try await loadProduct(id: productID) }
        guard let product = products[productID] else { throw StoreFailure.productNotFound }
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch {
            throw StoreFailure.failed(detail: String(describing: type(of: error)))
        }
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                return .purchased(StoreKitTransaction(transaction: transaction, signedJWS: verification.jwsRepresentation))
            case .unverified(_, let error):
                log.record("iap_unverified_on_device", ["context": "purchase", "reason": String(describing: type(of: error))])
                throw StoreFailure.unverified
            }
        case .userCancelled:
            return .cancelled
        case .pending:
            return .pending
        @unknown default:
            throw StoreFailure.failed(detail: "unknown_purchase_result")
        }
    }

    func syncWithAppStore() async throws {
        try await AppStore.sync()
    }

    func currentEntitlements(productID: String) async -> [StoreTransaction] {
        var found: [StoreTransaction] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.productID == productID else { continue }
            found.append(StoreKitTransaction(transaction: transaction, signedJWS: result.jwsRepresentation))
        }
        return found
    }

    func updates() -> AsyncStream<StoreTransaction> {
        let log = self.log
        return AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    switch result {
                    case .verified(let transaction):
                        continuation.yield(StoreKitTransaction(transaction: transaction, signedJWS: result.jwsRepresentation))
                    case .unverified(_, let error):
                        log.record("iap_unverified_on_device", ["context": "update", "reason": String(describing: type(of: error))])
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func periodText(_ period: Product.SubscriptionPeriod?) -> String {
        guard let period else { return "month" }
        let unit: String
        switch period.unit {
        case .day: unit = "day"
        case .week: unit = "week"
        case .month: unit = "month"
        case .year: unit = "year"
        @unknown default: unit = "period"
        }
        return period.value == 1 ? unit : "\(period.value) \(unit)s"
    }
}
