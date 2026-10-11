import Foundation
import StoreKit
import Observation
import KiraCore
import os

/// StoreKit 2 subscriptions. Entitlements come only from cryptographically verified
/// transactions (`VerificationResult.verified`); unverified ones are ignored.
/// Prices shown are those returned by the App Store for the user's storefront.
@MainActor
@Observable
final class SubscriptionManager {
    static let plusMonthly = "my.kira.plus.monthly"
    static let premiumMonthly = "my.kira.premium.monthly"
    static let productIDs: [String] = [premiumMonthly, plusMonthly]

    private(set) var products: [Product] = []
    private(set) var tier: SubscriptionTier = .free
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private var updatesTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "my.kira.app", category: "storekit")
    var onTierChange: ((SubscriptionTier) -> Void)?

    init() {}

    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refreshEntitlements()
            }
        }
        Task { await loadProducts(); await refreshEntitlements() }
    }

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: Self.productIDs).sorted { $0.price < $1.price }
            errorMessage = nil
        } catch {
            errorMessage = "Subscriptions are unavailable right now."
            logger.error("Product load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshEntitlements() async {
        var best: SubscriptionTier = .free
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            if let expiry = transaction.expirationDate, expiry < Date() { continue }
            best = max(best, Self.tier(for: transaction.productID))
        }
        tier = best
        onTierChange?(best)
    }

    static func tier(for productID: String) -> SubscriptionTier {
        switch productID {
        case premiumMonthly: return .premium
        case plusMonthly: return .plus
        default: return .free
        }
    }

    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    errorMessage = "The purchase couldn’t be verified."
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
            errorMessage = "Purchase failed. \(error.localizedDescription)"
            return false
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            errorMessage = "Couldn’t restore purchases. \(error.localizedDescription)"
        }
    }

    /// Lightweight check usable from App Intents (no instance needed).
    static func currentTier() async -> SubscriptionTier {
        var best: SubscriptionTier = .free
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.revocationDate == nil {
                best = max(best, tier(for: transaction.productID))
            }
        }
        return best
    }
}
