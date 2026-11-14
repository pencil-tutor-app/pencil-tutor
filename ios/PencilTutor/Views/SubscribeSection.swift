import SwiftUI

/// "Subscribe" and "Restore Purchases", under the code box. The price and the period are the App Store's own text, shown because
/// Apple requires an auto-renewing subscription to say what it costs and when it renews. Nothing here mentions any other way to pay.
struct SubscribeSection: View {
    @ObservedObject var manager: SubscriptionManager
    let privacyPolicyURL: URL?
    let termsURL: URL?

    var body: some View {
        VStack(spacing: 14) {
            switch manager.availability {
            case .loading:
                ProgressView()
            case .available(let product):
                Button {
                    Task { await manager.subscribe() }
                } label: {
                    Group {
                        if manager.busy == .buying {
                            ProgressView()
                        } else {
                            Text("Subscribe")
                        }
                    }
                    .font(.title2.weight(.semibold))
                    .frame(minWidth: 220, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(manager.busy != .idle)
                .accessibilityIdentifier("subscribeButton")

                Text(Self.terms(for: product))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .accessibilityIdentifier("subscriptionTerms")
            case .unavailable:
                Text(SubscriptionManager.Words.unavailable)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("subscriptionUnavailable")
            }

            Button {
                Task { await manager.restore() }
            } label: {
                if manager.busy == .restoring {
                    ProgressView()
                } else {
                    Text("Restore Purchases")
                }
            }
            .disabled(manager.busy != .idle)
            .accessibilityIdentifier("restorePurchasesButton")

            if let message = manager.message {
                Text(message)
                    .font(.title3)
                    .foregroundStyle(Color.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
                    .accessibilityIdentifier("subscriptionMessage")
            }

            if privacyPolicyURL != nil || termsURL != nil {
                HStack(spacing: 20) {
                    if let termsURL { Link("Terms of Use", destination: termsURL) }
                    if let privacyPolicyURL { Link("Privacy Policy", destination: privacyPolicyURL) }
                }
                .font(.footnote)
            }
        }
    }

    /// "CA$19.00 per month. Renews automatically until you cancel in your Apple account settings."
    static func terms(for product: SubscriptionProduct) -> String {
        let every = product.periodText.first?.isNumber == true ? "every \(product.periodText)" : "per \(product.periodText)"
        return "\(product.priceText) \(every). Renews automatically until you cancel in your Apple account settings."
    }
}
