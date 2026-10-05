import Foundation
import Observation
import StoreKit
import VectorCore

/// StoreKit 2 subscriptions. Prices always come from the App Store, so the
/// paywall can never show a made-up price or a fake discount.
@Observable
@MainActor
final class PurchaseService {
    enum Plan: String, CaseIterable, Identifiable {
        case annual = "app.vector.pro.annual"
        case monthly = "app.vector.pro.monthly"

        var id: String { rawValue }
        var title: String { self == .annual ? "Annual" : "Monthly" }
    }

    enum State: Equatable {
        case idle, loading, purchasing, failed(String)
    }

    private(set) var products: [Plan: Product] = [:]
    private(set) var state: State = .idle
    private(set) var isPro = false
    private(set) var eligibleForTrial: Bool = true
    var onTierChange: (@MainActor (SubscriptionTier) -> Void)?
    @ObservationIgnored private var updates: Task<Void, Never>?

    init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    await self?.refreshEntitlements()
                }
            }
        }
    }

    func load() async {
        guard products.isEmpty else { return }
        state = .loading
        do {
            let loaded = try await Product.products(for: Plan.allCases.map(\.rawValue))
            for product in loaded {
                if let plan = Plan(rawValue: product.id) { products[plan] = product }
            }
            if let annual = products[.annual], let subscription = annual.subscription {
                eligibleForTrial = await subscription.isEligibleForIntroOffer
            }
            state = .idle
        } catch {
            state = .failed("Couldn't reach the App Store. Check your connection and try again.")
        }
        await refreshEntitlements()
    }

    func purchase(_ plan: Plan) async -> Bool {
        guard let product = products[plan] else { return false }
        state = .purchasing
        defer { if state == .purchasing { state = .idle } }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    state = .failed("The purchase couldn't be verified.")
                    return false
                }
                await transaction.finish()
                await refreshEntitlements()
                return true
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            state = .failed("The purchase didn't go through. You haven't been charged.")
            return false
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    func refreshEntitlements() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               Plan(rawValue: transaction.productID) != nil,
               transaction.revocationDate == nil {
                active = true
            }
        }
        isPro = active
        onTierChange?(active ? .pro : .free)
    }

    // MARK: Honest price presentation

    func displayPrice(_ plan: Plan) -> String? { products[plan]?.displayPrice }

    /// Annual price expressed per month, derived from the real price.
    func annualMonthlyEquivalent() -> String? {
        guard let annual = products[.annual] else { return nil }
        return (annual.price / 12).formatted(annual.priceFormatStyle)
    }

    /// Savings of annual vs. twelve monthly payments, from real prices only.
    func annualSavingsPercent() -> Int? {
        guard let annual = products[.annual]?.price, let monthly = products[.monthly]?.price, monthly > 0 else { return nil }
        let yearly = monthly * 12
        let saving = (yearly - annual) / yearly * 100
        let value = NSDecimalNumber(decimal: saving).intValue
        return value > 0 ? value : nil
    }

    func trialDescription() -> String? {
        guard eligibleForTrial, let offer = products[.annual]?.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        let period = offer.period
        switch period.unit {
        case .day: return "\(period.value)-day free trial"
        case .week: return "\(period.value * 7)-day free trial"
        case .month: return "\(period.value)-month free trial"
        default: return "Free trial"
        }
    }
}
